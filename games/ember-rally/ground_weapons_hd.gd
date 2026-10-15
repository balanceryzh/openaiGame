extends Node3D
## Pre-existing, visual-only battlefield debris. Built once from source positions,
## then independent of corpse state, enemy deaths, pickups, and collision.
const NORMAL_COUNT := 18
const GROUND_CLEARANCE := 0.038
const SEED := 284763
var placements: Array[Dictionary] = []
var _terrain: Node
var _source_positions: Array[Vector2] = []
var _rng := RandomNumberGenerator.new()
var _material: StandardMaterial3D

func build(game: Node) -> void:
	build_from_sources(game.corpse_ecology.corpses, game.terrain, game.corpse_showcase)

func build_from_sources(corpses: Array, terrain: Node, showcase: bool = false) -> void:
	for child in get_children():
		remove_child(child)
		child.free()
	name = "PreexistingGroundWeapons"
	placements.clear()
	_terrain = terrain
	_source_positions.clear()
	for corpse in corpses:
		_source_positions.append(corpse.p)
	_rng.seed = SEED
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 1.0
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Evenly sample the full source list, rather than decorating only the opening
	# encounter. The layout remains identical on every retry.
	var target := corpses.size() if showcase else mini(NORMAL_COUNT, corpses.size())
	var used: Dictionary = {}
	for slot in range(target):
		var start := floori(float(slot) * corpses.size() / maxi(1, target))
		for retry in range(1 if showcase else corpses.size()):
			var index := (start + retry) % corpses.size()
			if used.has(index):
				continue
			var corpse: Dictionary = corpses[index]
			var kind := "sword" if slot % 2 == 0 else "axe"
			var placement := _find_placement(corpse, kind, showcase)
			if placement.is_empty():
				continue
			placement["source_index"] = index
			placements.append(placement)
			used[index] = true
			break
	for kind in ["sword", "axe"]:
		_make_batch(kind)

func _find_placement(corpse: Dictionary, kind: String, showcase: bool) -> Dictionary:
	var source: Vector2 = corpse.p
	var phase := _rng.randf_range(-PI, PI)
	for attempt in range(48):
		# Showcase props favour left/right beside the body and clear its label.
		var side := -1.0 if int(corpse.get("corpse_id", 0)) % 2 == 0 else 1.0
		var angle := (0.0 if side > 0.0 else PI) + _rng.randf_range(-0.32, 0.32) if showcase and attempt < 16 else phase + attempt * 2.399963
		var offset := Vector2.from_angle(angle) * (1.42 + float(attempt % 4) * 0.11)
		var at := source + offset
		var yaw := _rng.randf_range(-PI, PI)
		if not _placement_safe(at, yaw, source, kind):
			continue
		var too_close := false
		for previous in placements:
			if at.distance_to(previous.position) < 2.0:
				too_close = true
				break
		if too_close:
			continue
		return {"position": at, "yaw": yaw, "kind": kind,
			"ground_height": float(_terrain.floor_height(at)),
			"height": float(_terrain.floor_height(at)) + GROUND_CLEARANCE,
			"source_position": source, "corpse_id": corpse.get("corpse_id", -1)}
	return {}

func footprint_samples(at: Vector2, yaw: float, kind: String) -> Array[Vector2]:
	var samples: Array[Vector2] = []
	var extent_x := 0.39 if kind == "sword" else 0.68
	# Check the complete rectangular envelope (including the axe's wide head),
	# not just its root. Interior samples protect against narrow trench edges.
	var basis := Basis(Vector3.UP, yaw)
	for ix in range(5):
		for iz in range(7):
			var local := Vector3(lerpf(-extent_x, extent_x, ix / 4.0), 0, lerpf(-1.02, 0.86, iz / 6.0))
			var point := basis * local
			samples.append(at + Vector2(point.x, point.z))
	return samples

func _placement_safe(at: Vector2, yaw: float, source: Vector2, kind: String) -> bool:
	var floor_y: float = _terrain.floor_height(at)
	if floor_y < -0.05 or not _terrain.is_free(at, 0.15):
		return false
	var nearby_sources: Array[Vector2] = []
	for other_source in _source_positions:
		if other_source.distance_to(at) < 2.2:
			nearby_sources.append(other_source)
	for point in footprint_samples(at, yaw, kind):
		if not _terrain.is_free(point, 0.12) or absf(float(_terrain.floor_height(point)) - floor_y) > 0.012:
			return false
		for other_source in nearby_sources:
			if point.distance_to(other_source) < 0.62:
				return false
	# Nearby on the same bank; no visual association across a trench or wall.
	for step in range(7):
		var point := source.lerp(at, step / 6.0)
		if not _terrain.is_free(point, 0.1) or absf(float(_terrain.floor_height(point)) - floor_y) > 0.012:
			return false
	return true

func placement_transform(placement: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, float(placement.yaw)), Vector3(placement.position.x, placement.height, placement.position.y))

func _make_batch(kind: String) -> void:
	var group: Array[Dictionary] = []
	for placement in placements:
		if placement.kind == kind:
			group.append(placement)
	if group.is_empty():
		return
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.mesh = _make_sword_mesh() if kind == "sword" else _make_axe_mesh()
	instances.instance_count = group.size()
	for index in range(group.size()):
		instances.set_instance_transform(index, placement_transform(group[index]))
	var batch := MultiMeshInstance3D.new()
	batch.name = "ScatteredSwords" if kind == "sword" else "ScatteredAxes"
	batch.multimesh = instances
	batch.material_override = _material
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(batch)

func _make_sword_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	# A long pointed steel blade, dark central fuller, wide iron crossguard,
	# brown leather grip, and square pommel reuse the terrain's visual language.
	_prism(surface, [Vector2(-0.105,0.16),Vector2(-0.105,-0.79),Vector2(0,-1.0),Vector2(0.105,-0.79),Vector2(0.105,0.16)], 0.016, 0.076, Color("a4b4bf"))
	_box(surface, Vector3(0,0.079,-0.28), Vector3(0.032,0.008,0.88), Color("394552"))
	_box(surface, Vector3(0,0.065,0.19), Vector3(0.69,0.11,0.10), Color("303e51"))
	_box(surface, Vector3(0,0.055,0.45), Vector3(0.135,0.10,0.41), Color("6d4636"))
	for z in [0.31,0.43,0.55]:
		_box(surface, Vector3(0,0.11,z), Vector3(0.14,0.016,0.025), Color("9b6d45"))
	_box(surface, Vector3(0,0.065,0.70), Vector3(0.21,0.13,0.18), Color("596878"))
	return surface.commit()

func _make_axe_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Broad single-bit bearded axe: a wood haft passes visibly through the iron
	# socket; the spreading polygon blade and pale cutting bevel read at distance.
	_box(surface, Vector3(-0.10,0.07,0.03), Vector3(0.14,0.14,1.63), Color("9b6d45"))
	_box(surface, Vector3(-0.10,0.145,0.16), Vector3(0.040,0.016,1.23), Color("ba8b59"))
	_box(surface, Vector3(-0.10,0.074,0.63), Vector3(0.165,0.148,0.31), Color("654637"))
	_box(surface, Vector3(-0.10,0.09,-0.57), Vector3(0.29,0.18,0.27), Color("303e51"))
	_prism(surface, [Vector2(-0.04,-0.73),Vector2(0.29,-0.78),Vector2(0.53,-0.98),Vector2(0.64,-0.83),Vector2(0.65,-0.47),Vector2(0.50,-0.23),Vector2(0.20,-0.35),Vector2(-0.04,-0.40)], 0.023, 0.145, Color("8398a6"))
	_prism(surface, [Vector2(0.53,-0.98),Vector2(0.64,-0.83),Vector2(0.65,-0.47),Vector2(0.50,-0.23),Vector2(0.43,-0.29),Vector2(0.56,-0.50),Vector2(0.55,-0.80),Vector2(0.47,-0.91)], 0.019, 0.149, Color("c1cbd0"))
	_box(surface, Vector3(-0.29,0.085,-0.57), Vector3(0.18,0.12,0.19), Color("596878"))
	return surface.commit()

func _box(surface: SurfaceTool, center: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	var corners: Array[Vector2] = [Vector2(center.x-h.x,center.z-h.z),Vector2(center.x+h.x,center.z-h.z),Vector2(center.x+h.x,center.z+h.z),Vector2(center.x-h.x,center.z+h.z)]
	_prism(surface, corners, center.y-h.y, center.y+h.y, color)

func _prism(surface: SurfaceTool, polygon: Array, low: float, high: float, color: Color) -> void:
	var points := PackedVector2Array(polygon)
	var indices := Geometry2D.triangulate_polygon(points)
	for i in range(0, indices.size(), 3):
		var a: Vector2 = points[indices[i]]
		var b: Vector2 = points[indices[i+1]]
		var c: Vector2 = points[indices[i+2]]
		_triangle(surface, Vector3(a.x,high,a.y), Vector3(b.x,high,b.y), Vector3(c.x,high,c.y), Vector3.UP, color)
		_triangle(surface, Vector3(c.x,low,c.y), Vector3(b.x,low,b.y), Vector3(a.x,low,a.y), Vector3.DOWN, color.darkened(0.24))
	for i in range(points.size()):
		var a: Vector2 = points[i]
		var b: Vector2 = points[(i+1)%points.size()]
		var normal := Vector3(b.y-a.y,0,a.x-b.x).normalized()
		var al := Vector3(a.x,low,a.y)
		var bl := Vector3(b.x,low,b.y)
		var ah := Vector3(a.x,high,a.y)
		var bh := Vector3(b.x,high,b.y)
		_triangle(surface, al,bl,bh,normal,color.darkened(0.18))
		_triangle(surface, al,bh,ah,normal,color.darkened(0.18))

func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, color: Color) -> void:
	# Explicit normals and double-sided flat faces avoid smoothing the pixel-like
	# low-poly silhouette. A single vertex-colour material batches the whole prop.
	for point in [a,b,c]:
		surface.set_normal(normal)
		surface.set_color(color)
		surface.add_vertex(point)
