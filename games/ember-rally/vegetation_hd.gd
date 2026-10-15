extends Node3D
## Drawn static plant cutouts rooted in true 3D. Only their tops receive shader
## wind; this is not drawn frame animation. The source art remains unchanged.

const MANIFEST_PATH := "res://assets/vegetation/vegetation_manifest.json"
const VARIANT_NAMES := ["grass_short", "grass_medium", "grass_tall", "fern_low_a", "fern_low_b", "grass_dry_bent", "grass_broken", "grass_trampled"]
const CARD_PITCH := -1.0838971 # Same fixed 62.1-degree high view; no camera edits.
const ROOT_LIFT := 0.042
const WIND_AMPLITUDE := 0.038
const SEED := 26061487
# Wide clear cores include bridge approaches, the west crossing and rescue court.
const PROTECTED_ROUTES: Array[Rect2] = [
	Rect2(-2.55,-7.0,5.1,21.0), Rect2(6.8,-3.5,3.4,14.0),
	Rect2(-21.85,-2.3,3.7,8.7), Rect2(4.2,-7.4,8.0,7.2)]
# Keep existing wreck silhouettes and impact/puddle centers readable too.
const PROTECTED_DETAILS: Array[Rect2] = [
	Rect2(-11.1,5.7,3.5,3.1), Rect2(12.2,-8.3,3.7,3.1),
	Rect2(-6.65,8.7,2.3,1.4), Rect2(3.5,-8.0,1.6,1.2),
	Rect2(12.3,9.25,1.6,1.1), Rect2(2.35,7.45,2.3,1.1),
	Rect2(12.05,4.8,1.5,0.8)]

const VEGETATION_SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
uniform sampler2D plant_texture : source_color, filter_nearest_mipmap, repeat_disable;
uniform float game_clock = 0.0;
uniform float root_v = 0.96;
uniform vec4 source_rect_uv = vec4(0.0,0.0,1.0,1.0);
uniform float wind_strength = 0.038;
uniform vec3 leaf_tint : source_color = vec3(1.0, 1.0, 1.0);
void vertex() {
	// The lower root and transparent gutter never move. No wall-clock TIME.
	float height_fraction = clamp((root_v - UV.y) / max(root_v, 0.001), 0.0, 1.0);
	float phase = INSTANCE_CUSTOM.r * 6.28318530718;
	float sway = sin(game_clock * 1.45 + phase) * 0.72
		+ sin(game_clock * 2.17 + phase * 1.71) * 0.28;
	VERTEX.x += sway * wind_strength * height_fraction * height_fraction;
}
void fragment() {
	vec4 painted = texture(plant_texture, source_rect_uv.xy + UV * source_rect_uv.zw);
	// An opaque cutout writes real depth; transparent gaps discard entirely.
	// Deliberately never write ALPHA, which would select blended sorting.
	if (painted.a < 0.32) { discard; }
	ALBEDO = painted.rgb * leaf_tint;
	ROUGHNESS = 1.0;
}
"""

var placements: Array[Dictionary] = []
var materials: Array[ShaderMaterial] = []
var variant_metadata: Array[Dictionary] = []
var _meshes: Array[ArrayMesh] = []
var _built := false
var _clock := 0.0

func build(terrain: Node3D, batch_geometry := true) -> void:
	if _built:
		return
	_built = true
	name = "DrawnBattlefieldVegetation"
	_load_variants()
	placements = _authored_placements(terrain)
	if batch_geometry:
		_make_batches(terrain)
	else:
		_make_editable_clumps(terrain)
	set_meta("placement_seed",SEED)
	set_meta("plant_count",placements.size())
	set_meta("animation_scope","Drawn static clumps with root-locked local-top shader wind; no frame animation")

func _load_variants() -> void:
	var source: Dictionary = {}
	if FileAccess.file_exists(MANIFEST_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
		if parsed is Dictionary:
			source = parsed
	var variants: Array = source.get("variants",[])
	var atlas_path: String = source.get("source_atlas","res://assets/vegetation/native/vegetation_atlas_original.png")
	if ResourceLoader.exists(atlas_path.get_basename()+".webp"):atlas_path=atlas_path.get_basename()+".webp"
	var atlas: Texture2D = load(atlas_path)
	var shader := Shader.new()
	shader.code = VEGETATION_SHADER
	for index in range(VARIANT_NAMES.size()):
		var label: String = VARIANT_NAMES[index]
		var texture_path := "res://assets/vegetation/sprites/" + label + ".png"
		var spec: Dictionary = {}
		for value in variants:
			if value is Dictionary and value.get("name","") == label:
				spec = value
				break
		texture_path = spec.get("texture",texture_path)
		var texture: Texture2D = atlas
		if texture == null:
			push_error("Missing drawn vegetation sprite: " + texture_path)
			continue
		var source_rect: Array = spec.get("source_rect",[0,0,texture.get_width(),texture.get_height()])
		var image_size := Vector2(float(source_rect[2]),float(source_rect[3]))
		var atlas_uv := Vector4(float(source_rect[0])/texture.get_width(),float(source_rect[1])/texture.get_height(),image_size.x/texture.get_width(),image_size.y/texture.get_height())
		var root_px: Array = spec.get("root",[image_size.x*0.5,image_size.y*0.96])
		var root_uv := Vector2(float(root_px[0])/image_size.x,float(root_px[1])/image_size.y)
		var normalized := {"name":label,"texture":atlas_path,"source_rect":source_rect,"size":image_size,"root_uv":root_uv}
		variant_metadata.append(normalized)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.resource_name = "DrawnVegetation_" + label
		mat.set_shader_parameter("plant_texture",texture)
		mat.set_shader_parameter("root_v",root_uv.y)
		mat.set_shader_parameter("source_rect_uv",atlas_uv)
		mat.set_shader_parameter("wind_strength",0.018 if index==7 else WIND_AMPLITUDE)
		mat.set_shader_parameter("leaf_tint",Vector3.ONE)
		materials.append(mat)
		_meshes.append(_rooted_card(image_size,root_uv))

func _rooted_card(image_size: Vector2, root_uv: Vector2) -> ArrayMesh:
	# Six horizontal subdivisions allow only the upper painted leaves to bend;
	# roots use their measured source coordinate rather than the card's center.
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	var aspect := image_size.x/image_size.y
	var rows: Array[float] = [0.0,1.0/6.0,2.0/6.0,0.5,4.0/6.0,5.0/6.0,root_uv.y,1.0]
	rows.sort()
	for row in range(rows.size()-1):
		var top := rows[row]
		var bottom := rows[row+1]
		for uv in [Vector2(0,top),Vector2(0,bottom),Vector2(1,bottom),Vector2(0,top),Vector2(1,bottom),Vector2(1,top)]:
			builder.set_normal(Vector3(0,0,1))
			builder.set_uv(uv)
			builder.add_vertex(Vector3((uv.x-root_uv.x)*aspect,root_uv.y-uv.y,0))
	return builder.commit()

func _authored_placements(terrain: Node3D) -> Array[Dictionary]:
	# These are composed pockets tied to architecture, wet edges and damage.
	# Randomness only varies individual roots inside these named small pockets.
	# There is no global scatter, regular grid, collision or tall foreground belt.
	var zones := [
		_zone("FortNorthToe",Vector2(-13.6,-11.28),Vector2(4.4,0.28),8,[0,1,3,4],"wall"),
		_zone("FortWestOuter",Vector2(-18.75,-8.1),Vector2(0.3,2.5),7,[0,1,3,4],"wall"),
		_zone("FortInnerToe",Vector2(-11.0,-5.38),Vector2(2.6,0.24),7,[0,1,3],"wall"),
		_zone("NorthEastToe",Vector2(4.5,-11.32),Vector2(2.7,0.3),7,[0,1,4],"wall"),
		_zone("EastFortSide",Vector2(16.07,-8.9),Vector2(0.32,1.85),7,[0,1,3,4],"wall"),
		_zone("EastFortBack",Vector2(14.15,-12.1),Vector2(2.1,0.28),7,[0,1,3],"wall"),
		_zone("SouthWallToe",Vector2(-10.5,10.8),Vector2(2.35,0.30),7,[0,3,4],"wall"),
		_zone("EastLowCoverToe",Vector2(16.2,7.53),Vector2(2.2,0.28),7,[0,3,4],"wall"),
		_zone("WestWetNorth",Vector2(-10.2,-0.32),Vector2(4.9,0.28),9,[0,1,2,3],"wet"),
		_zone("WestWetSouth",Vector2(-9.25,4.31),Vector2(5.5,0.24),9,[0,1,2,4],"wet"),
		_zone("EastWetNorth",Vector2(16.2,-0.32),Vector2(5.2,0.27),8,[0,1,2,3],"wet"),
		_zone("EastWetSouth",Vector2(17.5,4.31),Vector2(4.3,0.23),8,[0,1,2,4],"wet"),
		_zone("PuddleWestRim",Vector2(4.65,8.75),Vector2(0.65,0.33),5,[0,1,3,4],"wet"),
		_zone("PuddleEastRim",Vector2(12.0,5.8),Vector2(0.45,0.26),4,[0,1,4],"wet"),
		_zone("NorthBurntFringe",Vector2(-9.8,-3.25),Vector2(1.95,0.32),6,[5,6],"scorch"),
		_zone("SouthImpactFringe",Vector2(-6.3,10.55),Vector2(1.2,0.30),5,[5,6],"scorch"),
		_zone("EastImpactFringe",Vector2(13.2,10.88),Vector2(1.25,0.30),5,[5,6],"scorch"),
		_zone("NorthImpactFringe",Vector2(3.52,-8.5),Vector2(0.7,0.28),4,[5,6],"scorch"),
		_zone("SouthPathLeft",Vector2(-2.96,8.0),Vector2(0.1,3.2),4,[7],"path_edge"),
		_zone("SouthPathRight",Vector2(2.99,11.4),Vector2(0.1,1.8),3,[7],"path_edge"),
		_zone("NorthPathLeft",Vector2(-3.0,-3.2),Vector2(0.1,2.0),3,[7],"path_edge"),
		_zone("EastPathRight",Vector2(10.64,7.6),Vector2(0.11,1.7),3,[7],"path_edge")]
	var out: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for zone in zones:
		var placed := 0
		for attempt in range(int(zone.count)*32):
			if placed >= int(zone.count):
				break
			var offset: Vector2 = Vector2(rng.randf_range(-1,1),rng.randf_range(-1,1))*zone.spread
			var at: Vector2 = zone.at + offset
			if not is_placement_safe(at,terrain):
				continue
			var crowded := false
			for previous in out:
				if at.distance_to(previous.position)<0.47:
					crowded = true
					break
			if crowded:
				continue
			var choices: Array = zone.variants
			var variant: int = choices[placed%choices.size()]
			var base_height: float = [0.60,0.79,1.05,0.696,0.756,0.61,0.51,0.28][variant]
			var scale := rng.randf_range(0.90,1.08)
			var height: float = base_height*scale
			# Taller growth is confined to rear wet edges; near routes stays low.
			var aspect := 1.0
			if variant < variant_metadata.size():
				var size: Vector2 = variant_metadata[variant].size
				aspect = size.x/size.y
			out.append({"position":at,"variant":variant,"scale":scale,"height":height,
				"width":height*aspect,"yaw":rng.randf_range(-0.12,0.12),
				"lean":rng.randf_range(-0.065,0.065),"phase":rng.randf(),
				"zone":zone.name,"category":zone.category})
			placed += 1
	return out

func _zone(label: String, at: Vector2, spread: Vector2, count: int, variants: Array, category: String) -> Dictionary:
	return {"name":label,"at":at,"spread":spread,"count":count,"variants":variants,"category":category}

func is_placement_safe(at: Vector2, terrain: Node3D) -> bool:
	if not terrain.is_free(at,0.23) or not is_zero_approx(float(terrain.floor_height(at))):
		return false
	for area in PROTECTED_ROUTES:
		if area.has_point(at):
			return false
	for area in PROTECTED_DETAILS:
		if area.has_point(at):
			return false
	# Keep roots, leaf bases, and top-wind bounds clear of the excavated lip.
	if at.x>-17.35 and at.y>-0.04 and at.y<4.06:
		return false
	return true

func _placement_transform(spec: Dictionary, terrain: Node3D) -> Transform3D:
	var at: Vector2 = spec.position
	var basis := Basis(Vector3.UP,float(spec.yaw))*Basis(Vector3.RIGHT,CARD_PITCH)*Basis(Vector3.BACK,float(spec.lean))
	basis = basis.scaled_local(Vector3.ONE*float(spec.height))
	return Transform3D(basis,Vector3(at.x,float(terrain.floor_height(at))+ROOT_LIFT,at.y))

func _make_batches(terrain: Node3D) -> void:
	for variant in range(materials.size()):
		var group: Array[Dictionary] = []
		for spec in placements:
			if int(spec.variant)==variant:
				group.append(spec)
		var instances := MultiMesh.new()
		instances.transform_format = MultiMesh.TRANSFORM_3D
		instances.use_custom_data = true
		instances.mesh = _meshes[variant]
		instances.instance_count = group.size()
		for i in range(group.size()):
			instances.set_instance_transform(i,_placement_transform(group[i],terrain))
			instances.set_instance_custom_data(i,Color(float(group[i].phase),0,0,1))
		var node := MultiMeshInstance3D.new()
		node.name = "DrawnClumps_" + str(VARIANT_NAMES[variant])
		node.multimesh = instances
		node.material_override = materials[variant]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)

func _make_editable_clumps(terrain: Node3D) -> void:
	for i in range(placements.size()):
		var spec: Dictionary = placements[i]
		var variant := int(spec.variant)
		if variant>=_meshes.size():
			continue
		var node := MeshInstance3D.new()
		node.name = "%s_%03d_%s" % [spec.zone,i,VARIANT_NAMES[variant]]
		node.mesh = _meshes[variant]
		node.material_override = materials[variant]
		node.transform = _placement_transform(spec,terrain)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.set_meta("vegetation_variant",VARIANT_NAMES[variant])
		node.set_meta("root_xz",spec.position)
		node.set_meta("zone",spec.zone)
		node.set_meta("wind_preview","Static at clock zero in this editable bake")
		add_child(node)

func set_game_clock(clock: float) -> void:
	_clock = clock
	for mat in materials:
		mat.set_shader_parameter("game_clock",clock)

static func wind_offset(height_fraction: float, phase: float, clock: float) -> float:
	var weight := clampf(height_fraction,0.0,1.0)
	var angle := phase*TAU
	var sway := sin(clock*1.45+angle)*0.72 + sin(clock*2.17+angle*1.71)*0.28
	return sway*WIND_AMPLITUDE*weight*weight
