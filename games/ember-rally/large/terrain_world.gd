extends Node3D
## Streamed presentation of the authoritative first-level terrain.
## INPUT: original 2D pixels. OUTPUT/API positions: X/Z world units, 50px = 1u.
## No physics bodies or alternate navigation: collision remains in logic_terrain.

const PIXELS_PER_UNIT := 50.0
const WORLD_SIZE := Vector2(200.0, 110.0)
const CHUNK_SIZE := 24.0
const MAX_CHUNKS := 12
const TRENCH_FLOOR := -1.25
const ROAD_WIDTH := 104.0 / PIXELS_PER_UNIT
const ROAD_GRID := 0.75 # World-locked lattice: 32 cells per streaming chunk.
const REGION_NAMES := ["残帆人类营地", "破阵战场", "焦土围城战场", "恶魔木垒"]
const VegetationSource := preload("res://vegetation_hd.gd")
const MainDrawbridge := preload("res://large/main_drawbridge.gd")
const EnvironmentDetails := preload("res://large/environment_details.gd")
const GroundSurfaceShader := preload("res://large/ground_surface.gdshader")
const RoadSurfaceShader := preload("res://large/road_surface.gdshader")

var main_drawbridge: Node3D
var environment_details: Node3D
var logic_terrain: RefCounted
var chunks: Dictionary = {}
var world_blockers: Array[Dictionary] = []
var world_bridges: Array[Rect2] = []
var world_routes: Array[PackedVector2Array] = []
var world_landmarks: Array[Dictionary] = []
var placements: Array[Dictionary] = []
var _ground_cuts: Array[Rect2] = []
var _materials: Dictionary = {}
var _ground_material_metrics: Dictionary = {}
var _vegetation_source: Node3D
var _vegetation_by_chunk: Dictionary = {}
var _landmark_by_chunk: Dictionary = {}
var _blockers_by_chunk: Dictionary = {}
var _last_region := Rect2i(-999,-999,0,0)
var _clock := -1.0
var _water_material: ShaderMaterial
var audit_geometry := false # Opt-in CPU transform records for headless mesh QA.
var _built := false
var _builds := 0
var _evictions := 0
var _peak_chunks := 0
var _unit_box: BoxMesh
var _unit_cylinder: CylinderMesh
var _batch: Dictionary = {}
var _surfaces: Dictionary = {}
var _chunk_node: Node3D
var _chunk_rect: Rect2
var _road_segments: Array[PackedVector2Array] = []
var _road_clearings: Array[Dictionary] = []
var _road_field_cache: Dictionary = {}

func build(source: RefCounted) -> void:
	if _built: return
	_built = true
	logic_terrain = source
	name = "StreamedAuthoritativeBattlefield"
	_make_materials()
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE
	_unit_cylinder = CylinderMesh.new()
	_unit_cylinder.top_radius = 0.5
	_unit_cylinder.bottom_radius = 0.5
	_unit_cylinder.height = 1.0
	_unit_cylinder.radial_segments = 8
	for i in range(source.blockers.size()):
		var b: Dictionary = source.blockers[i]
		var r: Rect2 = _to_world_rect(b.rect)
		world_blockers.append({"kind":b.kind,"rect":r,"source_index":i})
		if b.kind in ["trench","moat"]: _ground_cuts.append(r)
		var first := _chunk_of(r.position)
		var last := _chunk_of(r.end-Vector2.ONE*0.001)
		for z in range(first.y,last.y+1):
			for x in range(first.x,last.x+1):
				var key := Vector2i(x,z)
				if not _blockers_by_chunk.has(key): _blockers_by_chunk[key] = []
				_blockers_by_chunk[key].append(i)
	for source_bridge in source.bridges:
		var r: Rect2 = _to_world_rect(source_bridge)
		world_bridges.append(r)
		# The deck covers a real hole. It is never painted on intact terrain.
		_ground_cuts.append(r)
	for source_route in source.routes:
		var route := PackedVector2Array()
		for p in source_route: route.append(p/PIXELS_PER_UNIT)
		world_routes.append(route)
	for i in range(source.landmarks.size()):
		var marker: Dictionary = source.landmarks[i].duplicate()
		marker.p /= PIXELS_PER_UNIT
		marker["region_index"] = i
		world_landmarks.append(marker)
		var key := _chunk_of(marker.p)
		if not _landmark_by_chunk.has(key): _landmark_by_chunk[key] = []
		_landmark_by_chunk[key].append(i)
	_make_vegetation_specs()
	main_drawbridge = MainDrawbridge.new()
	add_child(main_drawbridge)
	main_drawbridge.setup(logic_terrain,_materials)
	environment_details = EnvironmentDetails.new()
	add_child(environment_details)
	environment_details.setup(self)
	set_meta("coordinate_contract","50 source pixels = 1 X/Z unit; no second map scaling")
	set_meta("terrain_ready",true)
	set_meta("collision_source","logic_terrain only; no added physics bodies")

func update_view(hero_px: Vector2, elapsed: float, view_rect_px: Rect2) -> void:
	if not _built: return
	environment_details.update_clock(elapsed)
	main_drawbridge.sync_state(elapsed,hero_px)
	if not is_equal_approx(_clock,elapsed):
		_clock = elapsed
		for mat in _vegetation_source.materials:
			mat.set_shader_parameter("game_clock",elapsed)
		_water_material.set_shader_parameter("game_clock",elapsed)
	var hero_world := hero_px/PIXELS_PER_UNIT
	# Actual projected camera footprint, with a small guard band. A 29-unit
	# 16:9 orthographic view can straddle FOUR columns near a chunk boundary.
	var region: Rect2i
	if view_rect_px.has_area():
		var view := _to_world_rect(view_rect_px).grow(1.25).intersection(Rect2(Vector2.ZERO,WORLD_SIZE))
		var first := _chunk_of(view.position)
		var last := _chunk_of(view.end-Vector2.ONE*0.001)
		region = Rect2i(first,Vector2i(mini(4,last.x-first.x+1),mini(3,last.y-first.y+1)))
	else:
		var center := _chunk_of(hero_world)
		region = Rect2i(center-Vector2i.ONE,Vector2i(3,3))
	if region == _last_region: return
	_last_region = region
	var desired: Dictionary = {}
	for z in range(region.position.y,region.end.y):
		for x in range(region.position.x,region.end.x):
			if x < 0 or z < 0 or x*CHUNK_SIZE>=WORLD_SIZE.x or z*CHUNK_SIZE>=WORLD_SIZE.y: continue
			desired[Vector2i(x,z)] = true
	# Free far meshes before building new ones, never accumulating a full level.
	for key in chunks.keys():
		if not desired.has(key):
			environment_details.detach_chunk(key)
			var old: Node3D = chunks[key]
			remove_child(old)
			old.free()
			chunks.erase(key)
			_evictions += 1
	for key in desired:
		if not chunks.has(key): _build_chunk(key)
	_peak_chunks = maxi(_peak_chunks,chunks.size())

func floor_height(world_xz: Vector2) -> float:
	# Bridge decks meet ground at y=0. No height trap or invisible ramp/rail.
	for r in world_bridges:
		if r.has_point(world_xz): return 0.0 if logic_terrain.bridge_open else TRENCH_FLOOR
	for b in world_blockers:
		if b.kind in ["trench","moat"] and b.rect.has_point(world_xz): return TRENCH_FLOOR
	return 0.0

func is_free(world_xz: Vector2, radiusworld: float = 0.36) -> bool:
	return logic_terrain != null and not logic_terrain.is_blocked(world_xz*PIXELS_PER_UNIT,radiusworld*PIXELS_PER_UNIT)

func get_stats() -> Dictionary:
	var batches := 0
	var instances := 0
	var triangles := 0
	var plants := 0
	for chunk in chunks.values():
		batches += int(chunk.get_meta("batch_count",0))
		instances += int(chunk.get_meta("instance_count",0))
		triangles += int(chunk.get_meta("surface_triangles",0))
		plants += int(chunk.get_meta("plant_count",0))
	return {"chunk_count":chunks.size(),"chunks":chunks.size(),"peak_chunks":_peak_chunks,"batches":batches,"mesh_batches":batches,"instances":instances,"surface_triangles":triangles,"plants":plants,"builds":_builds,"evictions":_evictions,"logic_blockers":world_blockers.size(),"bridges":world_bridges.size(),"routes":world_routes.size(),"world_units":WORLD_SIZE,"new_collision_bodies":0,"environment_details":environment_details.get_stats() if is_instance_valid(environment_details) else {}}

func _to_world_rect(rect: Rect2) -> Rect2:
	return Rect2(rect.position/PIXELS_PER_UNIT,rect.size/PIXELS_PER_UNIT)

func _chunk_of(at: Vector2) -> Vector2i:
	return Vector2i((at/CHUNK_SIZE).floor())

func _make_materials() -> void:
	for entry in [["earth",Color("343b3e")],["mortar",Color("39444a")],["wood",Color("604936")],["wood_light",Color("a07a52")],["iron",Color("303e49")],["red",Color("7d3e42")],["blue",Color("486173")],["gold",Color("b3a077")],["scorch",Color("2f3534")],["bark",Color("413b35")],["bell",Color("85724b")],["mud",Color("454539")]]:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = entry[1]
		mat.roughness = 1.0
		_materials[entry[0]] = mat
	for key in ["stone","stone_light"]:
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = load("res://assets/terrain/used_stone.png")
		mat.albedo_color = Color(0.64,0.73,0.78) if key=="stone" else Color(0.79,0.85,0.88)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
		mat.roughness = 1.0
		mat.uv1_triplanar = true
		mat.uv1_world_triplanar = true
		mat.uv1_scale = Vector3(0.9,1.2,0.9)
		_materials[key] = mat
	_make_camp_materials()
	_make_ground_materials()
	var water_shader := Shader.new()
	water_shader.code = """shader_type spatial;
render_mode cull_disabled;
uniform float game_clock = 0.0;
void fragment() {
	float band = sin(UV.x * 17.0 + UV.y * 23.0 + game_clock * 0.75);
	float glint = smoothstep(0.90, 1.0, band) * 0.085;
	ALBEDO = vec3(0.14, 0.205, 0.22) + vec3(glint * 0.6, glint * 0.9, glint);
	ROUGHNESS = 0.3;
	METALLIC = 0.15;
}
"""
	_water_material = ShaderMaterial.new()
	_water_material.shader = water_shader
	_materials["water"] = _water_material

func _make_camp_materials() -> void:
	# Full-size authored paintings; cloth tears belong to mesh silhouettes.
	for key in ["camp_canvas","demon_canvas","camp_wood","camp_wood_light"]:
		var cloth: bool = str(key).ends_with("canvas")
		var path := "res://assets/four_stage/army_canvas.webp" if cloth else "res://assets/four_stage/war_planks.webp"
		var png := path.get_base_dir()+"/source/"+path.get_file().get_basename()+".png"
		var mat := StandardMaterial3D.new()
		if ResourceLoader.exists(path): mat.albedo_texture = load(path)
		elif ResourceLoader.exists(png): mat.albedo_texture = load(png)
		mat.albedo_color = Color(0.88,0.87,0.80) if key=="camp_canvas" else Color(0.55,0.30,0.31) if key=="demon_canvas" else Color(0.80,0.74,0.65) if key=="camp_wood" else Color(1.0,0.95,0.85)
		mat.roughness = 1.0
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		if cloth: mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_materials[key] = mat

func _make_ground_materials() -> void:
	# Painted PNG masters are retained; lossless WebP is the preferred runtime
	# container. A source-only editor checkout works before runtime packaging.
	var textures: Dictionary = {}
	for name_key in ["grass","dirt"]:
		var runtime_path := "res://assets/ground_repaint/painted_grass.webp" if name_key=="grass" else "res://assets/road_repaint/painted_road.webp"
		var source_path := "res://assets/ground_repaint/source/painted_grass.png" if name_key=="grass" else "res://assets/road_repaint/source/painted_road.png"
		var path := runtime_path if ResourceLoader.exists(runtime_path) else source_path
		var texture: Texture2D = load(path) if ResourceLoader.exists(path) else null
		if texture == null:
			# This only permits the material interface to compile during painting.
			# Release QA asserts that both full-size authored assets loaded.
			var placeholder := Image.create(2,2,false,Image.FORMAT_RGB8)
			placeholder.fill(Color("687955") if name_key=="grass" else Color("998263"))
			texture = ImageTexture.create_from_image(placeholder)
			push_warning("Ground painting is not ready: "+source_path)
		textures[name_key] = texture
		_ground_material_metrics[name_key] = {"runtime_path":path,"source_path":source_path,"dimensions":texture.get_size(),"paint_ready":texture.get_width()>2,"world_space":true,"filter":"linear_mipmap","repeat":"C0 mirrored, clamped sampler","texture_samples":2}
	for key in ["ground","dirt","ash"]:
		var name_key := "grass" if key=="ground" else "dirt"
		var world_size := 32.0 if key=="ground" else 28.0
		var tint := Color(0.96,1.0,0.94) if key=="ground" else Color(0.99,0.98,0.95) if key=="dirt" else Color(0.87,0.89,0.91)
		var desaturation := 0.65 if key=="ash" else 0.12 if key=="ground" else 0.0
		var mat := ShaderMaterial.new()
		mat.shader = GroundSurfaceShader
		mat.set_shader_parameter("surface_texture",textures[name_key])
		mat.set_shader_parameter("texture_world_size",world_size)
		mat.set_shader_parameter("surface_tint",tint)
		mat.set_shader_parameter("secondary_weight",0.18)
		mat.set_shader_parameter("desaturation",desaturation)
		mat.set_shader_parameter("regional_ground",key=="ground")
		_materials[key] = mat
		_ground_material_metrics[key+"_surface"] = {"texture":name_key,"world_units_per_texture":world_size,"source_pixels_per_world_unit":textures[name_key].get_width()/world_size,"secondary_weight":0.18,"tint":tint,"desaturation":desaturation,"regional_tint_in_world_space":key=="ground"}
	# Scorched courts reuse the approved dirt painting instead of a flat-color
	# polygon. Only the material changes; authored geometry and navigation stay.
	var scorch: ShaderMaterial = _materials["ash"].duplicate()
	scorch.set_shader_parameter("surface_tint",Color(0.61,0.62,0.57))
	scorch.set_shader_parameter("desaturation",0.75)
	scorch.set_shader_parameter("texture_world_size",20.0)
	_materials["scorch"] = scorch
	_ground_material_metrics["scorch_surface"] = {"texture":"dirt","world_units_per_texture":20.0,"painted":true,"geometry_unchanged":true}
	# One opaque local road surface, with the same grass at its feathered edge.
	# Reuse the dirt texture also used by ash; no second full-size dirt asset.
	var road := ShaderMaterial.new()
	road.shader = RoadSurfaceShader
	road.set_shader_parameter("grass_texture",textures["grass"])
	road.set_shader_parameter("road_texture",textures["dirt"])
	_materials["road"] = road
	_ground_material_metrics["road_surface"] = {"texture":"dirt","grid_world_units":ROAD_GRID,"world_space":true,"opaque":true,"max_texture_samples":4,"no_separate_rut_meshes":true,"shared_dirt_runtime":true}

func get_ground_material_stats() -> Dictionary:
	return _ground_material_metrics.duplicate(true)

func _build_chunk(key: Vector2i) -> void:
	_chunk_node = Node3D.new()
	_chunk_node.name = "TerrainChunk_%02d_%02d" % [key.x,key.y]
	_chunk_rect = Rect2(Vector2(key)*CHUNK_SIZE,Vector2.ONE*CHUNK_SIZE).intersection(Rect2(Vector2.ZERO,WORLD_SIZE))
	_chunk_node.set_meta("world_rect",_chunk_rect)
	add_child(_chunk_node)
	chunks[key] = _chunk_node
	_batch = {}
	_surfaces = {}
	_make_land_surface()
	_make_roads()
	for index in _blockers_by_chunk.get(key,[]):
		var b: Dictionary = world_blockers[index]
		var clipped: Rect2 = b.rect.intersection(_chunk_rect)
		if b.kind in ["trench","moat"]:
			_make_trench(clipped)
		elif b.kind == "palisade":
			_make_palisade(b.rect,clipped,index)
		elif b.kind == "wall":
			_make_wall(b.rect,clipped,index)
		elif _chunk_of(b.rect.get_center()) == key:
			if b.kind == "wagon": _make_wagon(b.rect,index)
			elif b.kind == "barricade": _make_barricade(b.rect,index)
			elif b.kind == "tent": _make_tent(b.rect,index)
	for i in range(world_bridges.size()):
		if world_bridges[i].intersects(_chunk_rect): _make_bridge(world_bridges[i].intersection(_chunk_rect),i)
	for i in _landmark_by_chunk.get(key,[]): _make_landmark(world_landmarks[i])
	_make_regional_dressing(key)
	_make_wet_edges()
	_commit_batches()
	_commit_surfaces()
	_make_plant_batches(key)
	environment_details.attach_chunk(key,_chunk_node)
	_chunk_node.set_meta("source_blocker_count",_blockers_by_chunk.get(key,[]).size())
	_builds += 1

func _make_land_surface() -> void:
	var pieces: Array[Rect2] = [_chunk_rect]
	for cut in _ground_cuts:
		if not cut.intersects(_chunk_rect): continue
		var next: Array[Rect2] = []
		for piece in pieces: next.append_array(_subtract_rect(piece,cut))
		pieces = next
	for rect in pieces:
		_quad(rect,0.0,"ground",true)
	# Vertical sides are inset below the lip, never a blocker at ground level.
	for cut in _ground_cuts:
		if not cut.intersects(_chunk_rect): continue
		var r: Rect2 = cut.intersection(_chunk_rect)
		for x in [cut.position.x,cut.end.x]:
			if x>=_chunk_rect.position.x and x<=_chunk_rect.end.x:
				_box(Vector3(x,-0.63,r.get_center().y),Vector3(0.028,1.25,r.size.y),"earth")
		for z in [cut.position.y,cut.end.y]:
			if z>=_chunk_rect.position.y and z<=_chunk_rect.end.y:
				_box(Vector3(r.get_center().x,-0.63,z),Vector3(r.size.x,1.25,0.028),"earth")

func _subtract_rect(source: Rect2, cut: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if not source.intersects(cut):
		out.append(source)
		return out
	var overlap := source.intersection(cut)
	for r in [Rect2(source.position,Vector2(source.size.x,overlap.position.y-source.position.y)),Rect2(Vector2(source.position.x,overlap.end.y),Vector2(source.size.x,source.end.y-overlap.end.y)),Rect2(Vector2(source.position.x,overlap.position.y),Vector2(overlap.position.x-source.position.x,overlap.size.y)),Rect2(Vector2(overlap.end.x,overlap.position.y),Vector2(source.end.x-overlap.end.x,overlap.size.y))]:
		if r.size.x>0.0001 and r.size.y>0.0001: out.append(r)
	return out

func _make_roads() -> void:
	# Union the original centerlines and clearings as a distance field. The
	# logical routes are never moved/smoothed; round capsule joins and worn
	# shoulders are presentation only. Every grid cell is emitted once, even
	# at duplicate route segments, junctions and landmark clearing overlaps.
	_road_segments.clear()
	_road_clearings.clear()
	_road_field_cache.clear()
	for route in world_routes:
		for i in range(route.size()-1):
			var a := route[i]
			var b := route[i+1]
			if Rect2(a,Vector2.ZERO).expand(b).grow(3.0).intersects(_chunk_rect):
				_road_segments.append(PackedVector2Array([a,b]))
	for landmark in world_landmarks:
		var p: Vector2 = landmark.p
		if _chunk_rect.grow(5.5).has_point(p): _road_clearings.append(landmark)
	if _road_segments.is_empty() and _road_clearings.is_empty(): return
	var cuts: Array[Rect2] = []
	for cut in _ground_cuts:
		if cut.intersects(_chunk_rect): cuts.append(cut)
	var first := Vector2i((_chunk_rect.position/ROAD_GRID).round())
	var last := Vector2i((_chunk_rect.end/ROAD_GRID).ceil())
	for z in range(first.y,last.y):
		for x in range(first.x,last.x):
			var cell := Rect2(Vector2(x,z)*ROAD_GRID,Vector2.ONE*ROAD_GRID).intersection(_chunk_rect)
			# Conservative field support; the final corner test strips pure-grass
			# cells outside the interpolated .32-unit visible feather.
			if _road_field(cell.get_center()).x>1.4: continue
			var nearest_corner := INF
			for corner in _rect_polygon(cell): nearest_corner=minf(nearest_corner,_road_field(corner).x)
			if nearest_corner>0.40: continue
			var touches_cut := false
			for cut in cuts:
				if cell.intersects(cut): touches_cut=true; break
			if touches_cut: _clipped_surface(_rect_polygon(cell),0.012,"road")
			else: _quad(cell,0.012,"road")
	_chunk_node.set_meta("road_grid",ROAD_GRID)
	_chunk_node.set_meta("road_triangles",_surfaces["road"].triangles if _surfaces.has("road") else 0)

func _road_field(p: Vector2) -> Vector2:
	if _road_field_cache.has(p): return _road_field_cache[p]
	var distance := 8.0
	for segment in _road_segments:
		distance = minf(distance,p.distance_to(Geometry2D.get_closest_point_to_segment(p,segment[0],segment[1]))-ROAD_WIDTH*0.5)
	var ash := 0.0
	for marker in _road_clearings:
		var delta: Vector2 = (p-marker.p)/Vector2(3.5,2.9)
		var clearing := (delta.length()-1.0)*2.9
		distance = minf(distance,clearing)
		if int(marker.region_index) in [2,3,5,6,8]: ash=maxf(ash,1.0-smoothstep(-1.3,0.7,clearing))
	# Deterministic low-frequency edge wear, not texture grit. This evaluates
	# from absolute XZ on both sides of every chunk border and clipped cut.
	distance += 0.13*sin(p.x*2.10+p.y*1.70)+0.10*sin(p.x*0.70-p.y*1.30)+0.035*sin(p.x*5.0+p.y*0.8)
	var field := Vector2(distance,ash)
	_road_field_cache[p] = field
	return field

func _make_trench(r: Rect2) -> void:
	_quad(r,TRENCH_FLOOR,"ash")
	# Shoring follows each individual excavation's long axis, including the
	# horizontal middle-stage firing lines. It remains entirely below the lip.
	var horizontal := r.size.x >= r.size.y
	var length := r.size.x if horizontal else r.size.y
	var center := r.get_center()
	for sign_value in [-1.0,1.0]:
		var edge := center+Vector2(0,sign_value*(r.size.y*0.5-0.09)) if horizontal else center+Vector2(sign_value*(r.size.x*0.5-0.09),0)
		_box(Vector3(edge.x,-0.83,edge.y),Vector3(length,0.12,0.105) if horizontal else Vector3(0.105,0.12,length),"camp_wood")
		var start := r.position.x if horizontal else r.position.y
		for i in range(int(ceil(start/1.85)),int(floor((start+length)/1.85))+1):
			var p := Vector2(float(i)*1.85,edge.y) if horizontal else Vector2(edge.x,float(i)*1.85)
			_box(Vector3(p.x,-0.60,p.y),Vector3(0.12,1.15,0.12),"camp_wood")

func _make_bridge(r: Rect2, _index: int) -> void:
	# Dynamic deck is a single hinged object, never duplicated by streaming chunks.
	_quad(r,TRENCH_FLOOR,"earth")


func _make_palisade(full: Rect2, clipped: Rect2, index: int) -> void:
	var horizontal := full.size.x >= full.size.y
	var length := full.size.x if horizontal else full.size.y
	var count := maxi(2,ceili(length/0.38))
	var spacing := length/count
	var demon := full.get_center().x > 152.0
	var base_height := 2.35 if demon else 1.55
	# Continuous crossrails make the blocked outline visually legible; all
	# apparent gaps between logs are much narrower than a character.
	for h in [0.55,1.15]:
		_box(Vector3(clipped.get_center().x,h,clipped.get_center().y),Vector3(clipped.size.x,0.17,clipped.size.y*0.66),"camp_wood")
	for i in range(count):
		var p := full.position+Vector2((i+0.5)*spacing,full.size.y*0.5) if horizontal else full.position+Vector2(full.size.x*0.5,(i+0.5)*spacing)
		if not clipped.has_point(p): continue
		var h := base_height+sin(i*2.11+index)*0.23
		if (i+index)%9==0: h*=0.64
		var thickness := minf(spacing*0.95,0.36)
		_box(Vector3(p.x,h*0.5,p.y),Vector3(thickness,h,0.40) if horizontal else Vector3(0.40,h,thickness),"camp_wood_light" if (i+index)%4==0 else "camp_wood")
		var dx := thickness*0.5 if horizontal else 0.20
		var dz := 0.20 if horizontal else thickness*0.5
		var peak := Vector3(p.x+dx*0.22,h+0.37,p.y)
		var corners := [Vector3(p.x-dx,h,p.y-dz),Vector3(p.x+dx,h,p.y-dz),Vector3(p.x+dx,h,p.y+dz),Vector3(p.x-dx,h,p.y+dz)]
		for face in range(4): _mesh_triangle(corners[face],corners[(face+1)%4],peak,Vector2.ZERO,Vector2(1,0),Vector2(0.5,1),"camp_wood_light")

func _make_tent(r: Rect2, index: int) -> void:
	# A real A-frame ruin: sagging opaque canvas panels, torn-away wedges,
	# exposed beams, and collapsed cloth. Every ground-contact part stays in r.
	var c := r.get_center()
	var x0 := r.position.x+0.12
	var x1 := r.end.x-0.12
	var z0 := r.position.y+0.14
	var z1 := r.end.y-0.14
	var height := 2.50 if c.x>152 else 2.05+0.16*(index%3)
	var cloth := "demon_canvas" if c.x>152 else "camp_canvas"
	var ridge_a := Vector3(c.x,height,z0)
	var ridge_b := Vector3(c.x+0.22,height*0.80,z1)
	_beam(ridge_a,ridge_b,0.105,"camp_wood")
	for z in [z0+0.06,z1-0.06]:
		var roof_h := height if z< c.y else height*0.80
		_box(Vector3(c.x,roof_h*0.5,z),Vector3(0.12,roof_h,0.12),"camp_wood")
		for x in [x0+0.05,x1-0.05]:
			_beam(Vector3(x,0.12,z),Vector3(c.x,roof_h,z),0.095,"camp_wood")
	# Separate strips retain a large cloth silhouette while opening torn gaps.
	for side in [-1.0,1.0]:
		var edge_x := x0 if side<0 else x1
		for strip in range(3):
			var t0 := strip/3.0
			var t1 := (strip+1)/3.0
			var a := ridge_a.lerp(ridge_b,t0)
			var b := ridge_a.lerp(ridge_b,t1)
			var d := Vector3(edge_x,0.27+0.07*((index+strip)%2),lerpf(z0,z1,t0))
			var e := Vector3(edge_x+(0.16 if side<0 else -0.16),0.33,lerpf(z0,z1,t1))
			if strip==1 and side<0:
				# One split panel has an unmistakable triangular missing wedge.
				var tear := a.lerp(e,0.42)
				_mesh_triangle(a,b,tear,Vector2(0,t0),Vector2(0,t1),Vector2(0.5,(t0+t1)*0.5),cloth)
				_mesh_triangle(a,tear,d,Vector2(0,t0),Vector2(0.5,(t0+t1)*0.5),Vector2(1,t0),cloth)
			else:
				_mesh_triangle(a,b,e,Vector2(0,t0),Vector2(0,t1),Vector2(1,t1),cloth)
				_mesh_triangle(a,e,d,Vector2(0,t0),Vector2(1,t1),Vector2(1,t0),cloth)
		# Front flap is ripped open to expose the physical tent frame.
		var flap_top := Vector3(c.x,height,z0)
		var flap_side := Vector3(edge_x,0.24,z0)
		var flap_tip := Vector3(lerpf(c.x,edge_x,0.64),0.17,z0+0.16)
		_mesh_triangle(flap_top,flap_side,flap_tip,Vector2(0.5,0),Vector2(0,1),Vector2(0.32,1),cloth)
	# Low remains eliminate invisible open-floor blockers underneath a ruin.
	_box(Vector3(c.x,0.13,c.y),Vector3(r.size.x*0.42,0.26,r.size.y*0.60),"camp_wood")
	_mesh_triangle(Vector3(x0+0.1,0.055,z1-0.9),Vector3(x1-0.15,0.055,z1-0.5),Vector3(c.x,0.065,z1-0.05),Vector2.ZERO,Vector2(1,0),Vector2(0.5,1),cloth)

func _make_wall(full: Rect2, clipped: Rect2, index: int) -> void:
	var center := full.get_center()
	var horizontal := full.size.x>=full.size.y
	var length := full.size.x if horizontal else full.size.y
	var height := 1.05+float(index%5)*0.20
	if center.x>164: height+=0.55
	elif center.distance_to(Vector2(118,54))<16: height+=0.35
	_box(Vector3(clipped.get_center().x,height*0.40,clipped.get_center().y),Vector3(clipped.size.x,height*0.8,clipped.size.y),"mortar")
	var count := maxi(1,ceili(length/0.95))
	var unit := length/count
	var rows := maxi(2,ceili(height/0.43))
	for row in range(rows):
		for i in range(count+row%2):
			var start := maxf(0.0,unit*i-unit*0.5*(row%2))
			var end := minf(length,unit*(i+1)-unit*0.5*(row%2))
			if row==rows-1 and (i+index)%4==1: continue
			var brick := Rect2(full.position+Vector2(start,0) if horizontal else full.position+Vector2(0,start),Vector2(end-start,full.size.y) if horizontal else Vector2(full.size.x,end-start))
			brick = brick.intersection(clipped)
			if not brick.has_area(): continue
			var bh := height/rows
			var p := brick.get_center()
			_box(Vector3(p.x,row*bh+bh*0.5,p.y),Vector3(maxf(0.025,brick.size.x-0.035),bh-0.026,maxf(0.025,brick.size.y-0.035)),"stone_light" if (i+row+index)%6==0 else "stone")
	# A few low broken caps stay fully inside the exact authoritative footprint.
	for i in range(count):
		if (i+index)%3!=0: continue
		var p := full.position+Vector2(unit*(i+0.5),full.size.y*0.5) if horizontal else full.position+Vector2(full.size.x*0.5,unit*(i+0.5))
		if not clipped.has_point(p): continue
		_box(Vector3(p.x,height+0.06,p.y),Vector3(unit*0.60,0.12,full.size.y*0.82) if horizontal else Vector3(full.size.x*0.82,0.12,unit*0.60),"stone_light")

func _make_barricade(r: Rect2, index: int) -> void:
	# Ruined chevaux-de-frise, only on the two middle battlefields. Crossing
	# slanted timbers make these visibly different from the camp palisades.
	var horizontal := r.size.x>=r.size.y
	var center := r.get_center()
	var length := r.size.x if horizontal else r.size.y
	var depth := r.size.y if horizontal else r.size.x
	_box(Vector3(center.x,0.70,center.y),Vector3(length*0.96,0.23,0.23) if horizontal else Vector3(0.23,0.23,length*0.96),"camp_wood")
	var count := maxi(3,ceili(length/0.94))
	for i in range(count):
		var p := r.position+Vector2(r.size.x*(i+0.5)/count,r.size.y*0.5) if horizontal else r.position+Vector2(r.size.x*0.5,r.size.y*(i+0.5)/count)
		var h := 1.15+float((i+index)%3)*0.13
		for sign_value in [-1.0,1.0]:
			var shift := Vector3(0,0,depth*0.42*sign_value) if horizontal else Vector3(depth*0.42*sign_value,0,0)
			_beam(Vector3(p.x,0.15,p.y)+shift,Vector3(p.x,h,p.y)-shift,0.17,"camp_wood_light")
		_box(Vector3(p.x,0.12,p.y),Vector3(0.40,0.24,depth*0.94) if horizontal else Vector3(depth*0.94,0.24,0.40),"camp_wood")
		_box(Vector3(p.x,0.73,p.y),Vector3(0.28,0.12,0.30),"iron")

func _make_wagon(r: Rect2, index: int) -> void:
	# Existing broken-cart language, fitted entirely to its original blocker AABB.
	var p := r.get_center()
	for i in range(6):
		if i==2 and index%2==0: continue
		_box(Vector3(r.position.x+r.size.x*(i+0.5)/6,0.32,p.y),Vector3(r.size.x/6-0.035,0.12,r.size.y*0.60),"wood_light")
	for x in [-0.30,0.30]:
		_box(Vector3(p.x+x*r.size.x,0.25,p.y),Vector3(0.12,0.18,r.size.y*0.76),"iron")
	for z in [-0.29,0.29]:
		_box(Vector3(p.x,0.47,p.y+r.size.y*z),Vector3(r.size.x*0.93,0.16,0.12),"wood")
		for dx in [-0.33,0.33]:
			_wheel(Vector3(p.x+r.size.x*dx,0.38,p.y+r.size.y*z),minf(0.36,r.size.y*0.28),index%2==0)
	_box(Vector3(p.x-r.size.x*0.1,0.57,p.y),Vector3(r.size.x*0.29,0.38,r.size.y*0.43),"wood")
	_box(Vector3(p.x-r.size.x*0.1,0.76,p.y),Vector3(r.size.x*0.31,0.07,r.size.y*0.46),"wood_light")

func _wheel(center: Vector3, radius: float, broken := false) -> void:
	for i in range(10):
		if broken and i in [1,2]: continue
		var a := TAU*i/10
		var b := TAU*(i+1)/10
		_beam(center+Vector3(cos(a),sin(a),0)*radius,center+Vector3(cos(b),sin(b),0)*radius,0.075,"wood_light")
	for i in range(4):
		var a := TAU*i/4
		_beam(center,center+Vector3(cos(a),sin(a),0)*radius,0.055,"wood")
	_box(center,Vector3(0.14,0.14,0.15),"iron")

func _make_landmark(marker: Dictionary) -> void:
	# Landmark feet are authored on real blocker footprints. The visual marks
	# describe four continuous stages, rather than six identical rescue boxes.
	match str(marker.kind):
		"human_camp":
			_banner(Vector2(28.7,33.9),"blue",4.1)
			_banner(Vector2(17.0,34.7),"gold",3.2)
		"battlefield", "siege":
			# Middle stages have only trenches and ground dressing. No stone
			# landmark feet, ruined wall arches or fence-like above-ground props.
			pass
		"demon_camp":
			_banner(Vector2(179.0,23.5),"red",5.5)
			_banner(Vector2(194.3,57.0),"red",5.2)
			# A flat, walkable scorched commander court, no hidden platform lip.
			_irregular_patch(marker.p,Vector2(5.0,4.3),0.026,"scorch",0.28)
func _make_regional_dressing(_key: Vector2i) -> void:
	# Each scar belongs to a district and appears only where it is authored.
	for spec in [Vector3(66.0,2.7,48.0),Vector3(85.5,2.3,61.8),Vector3(91.0,2.8,83.2),Vector3(114.0,3.4,51.5),Vector3(131.5,3.2,62.0),Vector3(145.0,2.6,45.0)]:
		var p := Vector2(spec.x,spec.z)
		if not _chunk_rect.grow(spec.y).has_point(p): continue
		var poly := PackedVector2Array()
		for i in range(9):
			var a := TAU*i/9
			poly.append(p+Vector2(cos(a),sin(a)*0.68)*spec.y*(0.8+0.2*cos(i*2.1)))
		_clipped_surface(poly,0.028,"scorch")

func _make_wet_edges() -> void:
	# Modest authored wet pockets beside cover; no full-map weather or extra light.
	var pockets: Array[Vector2] = [Vector2(27.1,87.5),Vector2(39.0,80.8),Vector2(65.7,76.6),Vector2(114.1,58.8),Vector2(150.2,68.1),Vector2(175.7,25.1)]
	for b in world_blockers:
		if b.kind!="trench": continue
		var r: Rect2 = b.rect
		if r.size.y<9: continue
		pockets.append(Vector2(r.position.x-0.73,r.position.y+r.size.y*0.33))
	for p in pockets:
		if not _chunk_rect.grow(1.0).has_point(p) or not is_free(p,0.31) or _distance_to_road(p)<1.7: continue
		_irregular_patch(p,Vector2(0.92,0.53),0.025,"mud",-0.35)
		_irregular_patch(p,Vector2(0.73,0.34),0.028,"water",-0.35)

func _irregular_patch(p: Vector2, radii: Vector2, height: float, key: String, angle := 0.0) -> void:
	var poly := PackedVector2Array()
	for i in range(9):
		var a := TAU*i/9
		var point := Vector2(cos(a),sin(a))*radii*(0.88+0.12*sin(i*2.61+p.x))
		poly.append(p+point.rotated(angle))
	_clipped_surface(poly,height,key)

func _burned_tree(p: Vector2, height: float) -> void:
	_box(Vector3(p.x,height*0.40,p.y),Vector3(0.22,height*0.8,0.24),"bark")
	for sign_value in [-1.0,1.0]:
		var fork := Vector3(p.x+sign_value*0.63,height*0.86,p.y+sign_value*0.18)
		_beam(Vector3(p.x,height*0.49,p.y),fork,0.13,"bark")
		_beam(fork,Vector3(fork.x+sign_value*0.13,height+0.36,fork.z),0.075,"scorch")
		_beam(Vector3(p.x,height*0.7,p.y),Vector3(p.x+sign_value*0.32,height*1.1,p.y-0.35),0.08,"bark")

func _banner(p: Vector2, color: String, height: float) -> void:
	_box(Vector3(p.x,height*0.5,p.y),Vector3(0.07,height,0.07),"wood")
	_box(Vector3(p.x+0.37,height-0.18,p.y),Vector3(0.83,0.07,0.07),"wood_light")
	_box(Vector3(p.x+0.36,height-0.70,p.y),Vector3(0.69,1.02,0.035),color)
	_box(Vector3(p.x+0.35,height-0.74,p.y+0.022),Vector3(0.075,0.9,0.022),"gold")
	# Ragged, separated lower pennant strips give each flag a damaged edge.
	for i in range(3):
		_box(Vector3(p.x+0.16+i*0.20,height-1.30+float(i%2)*0.08,p.y),Vector3(0.15,0.20,0.03),color)

func _box(position3: Vector3, size: Vector3, key: String, rotation3 := Vector3.ZERO) -> void:
	if size.x<=0 or size.y<=0 or size.z<=0: return
	if not _batch.has(key): _batch[key] = []
	var basis := Basis.from_euler(rotation3).scaled_local(size)
	_batch[key].append(Transform3D(basis,position3))

func _cylinder(position3: Vector3, size: Vector3, key: String) -> void:
	var name_key := key+":cylinder"
	if not _batch.has(name_key): _batch[name_key] = []
	_batch[name_key].append(Transform3D(Basis.IDENTITY.scaled(size),position3))

func _beam(a: Vector3, b: Vector3, thickness: float, key: String) -> void:
	if a.is_equal_approx(b): return
	var direction := (b-a).normalized()
	var up := Vector3.UP if absf(direction.dot(Vector3.UP))<0.95 else Vector3.RIGHT
	var basis := Basis.looking_at(direction,up).scaled_local(Vector3(thickness,thickness,a.distance_to(b)))
	if not _batch.has(key): _batch[key] = []
	_batch[key].append(Transform3D(basis,(a+b)*0.5))

func _commit_batches() -> void:
	var instances := 0
	for key in _batch:
		var transforms: Array = _batch[key]
		if transforms.is_empty(): continue
		var mesh := MultiMesh.new()
		mesh.transform_format = MultiMesh.TRANSFORM_3D
		mesh.mesh = _unit_cylinder if key.ends_with(":cylinder") else _unit_box
		mesh.instance_count = transforms.size()
		for i in range(transforms.size()): mesh.set_instance_transform(i,transforms[i])
		var node := MultiMeshInstance3D.new()
		node.name = "Batched_"+key.replace(":","_")
		node.multimesh = mesh
		node.material_override = _materials[key.replace(":cylinder","")]
		if audit_geometry: node.set_meta("authored_transforms",transforms.duplicate())
		_chunk_node.add_child(node)
		instances += transforms.size()
	_chunk_node.set_meta("batch_count",_batch.size())
	_chunk_node.set_meta("instance_count",instances)

func _quad(rect: Rect2, height: float, material_key: String, ground := false) -> void:
	var a := rect.position
	var b := rect.position+Vector2(rect.size.x,0)
	var c := rect.end
	var d := rect.position+Vector2(0,rect.size.y)
	_triangle(a,b,c,height,material_key,ground)
	_triangle(a,c,d,height,material_key,ground)

func _triangle(a: Vector2, b: Vector2, c: Vector2, height: float, material_key: String, ground := false) -> void:
	if not _surfaces.has(material_key):
		var builder := SurfaceTool.new()
		builder.begin(Mesh.PRIMITIVE_TRIANGLES)
		_surfaces[material_key] = {"builder":builder,"triangles":0}
	var builder: SurfaceTool = _surfaces[material_key].builder
	if (b-a).cross(c-a)<0:
		var temp := b
		b = c
		c = temp
	for p in [a,b,c]:
		builder.set_normal(Vector3.UP)
		builder.set_uv(_road_field(p) if material_key=="road" else p/WORLD_SIZE if ground else p/3.0)
		builder.set_color(_regional_tint(p) if ground else Color.WHITE)
		builder.add_vertex(Vector3(p.x,height,p.y))
	_surfaces[material_key].triangles += 1

func _mesh_triangle(a: Vector3, b: Vector3, c: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, key: String) -> void:
	if not _surfaces.has(key):
		var builder := SurfaceTool.new()
		builder.begin(Mesh.PRIMITIVE_TRIANGLES)
		_surfaces[key] = {"builder":builder,"triangles":0}
	var builder: SurfaceTool = _surfaces[key].builder
	var normal := -(b-a).cross(c-a).normalized()
	if key.ends_with("canvas") and normal.y < -0.2:
		var point_swap := b
		b = c
		c = point_swap
		var uv_swap := ub
		ub = uc
		uc = uv_swap
		normal = -normal
	for vertex in [[a,ua],[b,ub],[c,uc]]:
		builder.set_normal(normal)
		builder.set_uv(vertex[1])
		builder.set_color(Color.WHITE)
		builder.add_vertex(vertex[0])
	_surfaces[key].triangles += 1

func _regional_tint(p: Vector2) -> Color:
	# Gentle continuous palette variation, not repeated miniature arenas.
	var charred := exp(-p.distance_squared_to(Vector2(94,88))/130.0)*0.22
	var north := smoothstep(100.0,180.0,p.x)*smoothstep(55.0,10.0,p.y)*0.12
	return Color(1.0-charred-north*0.5,1.0-charred,1.0-charred+north*0.4)

func _rect_polygon(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position,r.position+Vector2(r.size.x,0),r.end,r.position+Vector2(0,r.size.y)])

func _clipped_surface(poly: PackedVector2Array, height: float, key: String) -> void:
	var polygons: Array[PackedVector2Array] = []
	polygons.append_array(Geometry2D.intersect_polygons(poly,_rect_polygon(_chunk_rect)))
	for cut in _ground_cuts:
		if not cut.intersects(_chunk_rect): continue
		var next: Array[PackedVector2Array] = []
		for polygon in polygons: next.append_array(Geometry2D.clip_polygons(polygon,_rect_polygon(cut)))
		polygons = next
	for polygon in polygons:
		var indices := Geometry2D.triangulate_polygon(polygon)
		for i in range(0,indices.size(),3): _triangle(polygon[indices[i]],polygon[indices[i+1]],polygon[indices[i+2]],height,key)

func _commit_surfaces() -> void:
	var count := 0
	for key in _surfaces:
		var surface: Dictionary = _surfaces[key]
		var node := MeshInstance3D.new()
		node.name = "Surface_"+key
		node.mesh = surface.builder.commit()
		node.material_override = _materials[key]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if str(key).ends_with("canvas") else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_chunk_node.add_child(node)
		count += int(surface.triangles)
	_chunk_node.set_meta("surface_triangles",count)
	_chunk_node.set_meta("batch_count",int(_chunk_node.get_meta("batch_count",0))+_surfaces.size())

func _make_vegetation_specs() -> void:
	# Reuse the unchanged original atlas, measured roots and root-locked shader.
	# Never call its sample build: only its reusable source material/card helpers.
	_vegetation_source = VegetationSource.new()
	_vegetation_source.name = "SourceVegetationResources"
	_vegetation_source._load_variants()
	add_child(_vegetation_source)
	for i in range(world_blockers.size()):
		var b: Dictionary = world_blockers[i]
		if b.kind not in ["wall","trench","palisade","moat"]: continue
		var r: Rect2 = b.rect
		var is_trench: bool = b.kind in ["trench","moat"]
		var count := mini(8,maxi(2,int((r.size.x+r.size.y)/(2.9 if is_trench else 1.8))))
		for n in range(count):
			var f := (n+0.45)/count
			var offset := 0.31+0.18*sin(i*1.71+n*2.34)
			var p := Vector2(r.position.x-0.48-offset,r.position.y+r.size.y*f) if is_trench or r.size.y>r.size.x else Vector2(r.position.x+r.size.x*f,r.end.y+0.40+offset)
			if not is_free(p,0.27) or _distance_to_road(p)<ROAD_WIDTH*0.5+0.65: continue
			var safe := true
			for marker in world_landmarks:
				if p.distance_to(marker.p)<3.8: safe=false; break
			if not safe: continue
			var variant := (i+n)%5
			if p.distance_to(Vector2(94,88))<15: variant=5+(i+n)%2
			var h: float = [0.56,0.71,0.92,0.62,0.69,0.54,0.48,0.27][variant]
			var spec := {"position":p,"variant":variant,"height":h,"phase":fmod(i*0.371+n*0.173,1.0),"category":"wet" if is_trench else "wall"}
			placements.append(spec)
			var key := _chunk_of(p)
			if not _vegetation_by_chunk.has(key): _vegetation_by_chunk[key] = []
			_vegetation_by_chunk[key].append(spec)

func _distance_to_road(p: Vector2) -> float:
	var distance := INF
	for route in world_routes:
		for i in range(route.size()-1):
			distance = minf(distance,p.distance_to(Geometry2D.get_closest_point_to_segment(p,route[i],route[i+1])))
	return distance

func _make_plant_batches(key: Vector2i) -> void:
	var group: Array = _vegetation_by_chunk.get(key,[])
	var batch_count := 0
	for variant in range(_vegetation_source.materials.size()):
		var matching: Array = []
		for spec in group:
			if int(spec.variant)==variant: matching.append(spec)
		if matching.is_empty(): continue
		var mesh := MultiMesh.new()
		mesh.transform_format = MultiMesh.TRANSFORM_3D
		mesh.use_custom_data = true
		mesh.mesh = _vegetation_source._meshes[variant]
		mesh.instance_count = matching.size()
		for i in range(matching.size()):
			var spec: Dictionary = matching[i]
			var p: Vector2 = spec.position
			var basis := Basis(Vector3.RIGHT,VegetationSource.CARD_PITCH).scaled_local(Vector3.ONE*float(spec.height))
			mesh.set_instance_transform(i,Transform3D(basis,Vector3(p.x,0.042,p.y)))
			mesh.set_instance_custom_data(i,Color(float(spec.phase),0,0,1))
		var node := MultiMeshInstance3D.new()
		node.name = "RootedVegetation_%d" % variant
		node.multimesh = mesh
		node.material_override = _vegetation_source.materials[variant]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_chunk_node.add_child(node)
		batch_count += 1
	_chunk_node.set_meta("plant_count",group.size())
	_chunk_node.set_meta("batch_count",int(_chunk_node.get_meta("batch_count",0))+batch_count)
	_chunk_node.set_meta("instance_count",int(_chunk_node.get_meta("instance_count",0))+group.size())
