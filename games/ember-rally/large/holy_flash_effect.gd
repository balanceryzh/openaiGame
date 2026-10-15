extends Node3D
## A simulation-driven, terrain-following 3D flash. It never applies damage.
## The outer contour stays at the authoritative 10-yard radius throughout.
const PIXELS_PER_UNIT := 50.0
const DURATION := 0.72
const SEGMENTS := 96
var adapter: Node3D
var center_world := Vector2.ZERO
var radius_world := 10.0
var elapsed := DURATION
var perimeter: MeshInstance3D
var wave: MeshInstance3D
var wash: MeshInstance3D
var column: MeshInstance3D
var perimeter_material: StandardMaterial3D
var wave_material: StandardMaterial3D
var wash_material: StandardMaterial3D
var column_material: StandardMaterial3D

func setup(view_adapter: Node3D) -> void:
	adapter = view_adapter
	perimeter_material = _material(Color(1.0, 0.88, 0.45, 0.92))
	wave_material = _material(Color(1.0, 0.98, 0.86, 0.9))
	wash_material = _material(Color(1.0, 0.90, 0.55, 0.14))
	column_material = _material(Color(1.0, 0.98, 0.84, 0.7))
	perimeter = _node("ExactTenYardPerimeter", perimeter_material)
	wave = _node("ExpandingWhiteGoldWave", wave_material)
	wash = _node("GroundLightWash", wash_material)
	column = _node("HeroHolyLight", column_material)
	var beam := CylinderMesh.new()
	beam.top_radius = 0.12
	beam.bottom_radius = 0.65
	beam.height = 4.0
	beam.radial_segments = 24
	column.mesh = beam
	visible = false
	set_process(false)

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b)
	material.emission_energy_multiplier = 1.1
	return material

func _node(label: String, material: StandardMaterial3D) -> MeshInstance3D:
	var mesh_node := MeshInstance3D.new()
	mesh_node.name = label
	mesh_node.material_override = material
	mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_node)
	return mesh_node

func play_at(center_px: Vector2, radius_px: float) -> void:
	center_world = center_px / PIXELS_PER_UNIT
	radius_world = radius_px / PIXELS_PER_UNIT
	position = Vector3(center_world.x, 0.0, center_world.y)
	perimeter.mesh = _annulus(radius_world - 0.13, radius_world, 0.095)
	wash.mesh = _annulus(0.0, radius_world, 0.075)
	column.position = Vector3(0.0, _height(center_world) + 2.05, 0.0)
	elapsed = 0.0
	visible = true
	_update_visual()

func advance(dt: float) -> void:
	if not visible or dt <= 0.0: return
	elapsed = minf(DURATION, elapsed + dt)
	if elapsed >= DURATION:
		clear()
		return
	_update_visual()

func clear() -> void:
	elapsed = DURATION
	visible = false

func _update_visual() -> void:
	var progress := clampf(elapsed / DURATION, 0.0, 1.0)
	var fade := 1.0 - progress
	var wave_radius := radius_world * minf(1.0, 0.04 + progress / 0.72)
	wave.mesh = _annulus(maxf(0.0, wave_radius - 0.3), wave_radius, 0.12)
	_set_alpha(perimeter_material, 0.95 * fade)
	_set_alpha(wave_material, 0.90 * fade)
	_set_alpha(wash_material, 0.18 * fade * fade)
	_set_alpha(column_material, 0.70 * fade * fade)
	column.scale = Vector3(1.0 + progress * 0.65, 1.0, 1.0 + progress * 0.65)

func _set_alpha(material: StandardMaterial3D, alpha: float) -> void:
	var color := material.albedo_color
	color.a = alpha
	material.albedo_color = color

func _height(point: Vector2) -> float:
	if is_instance_valid(adapter):
		var terrain = adapter.get("terrain")
		if is_instance_valid(terrain) and terrain.has_method("floor_height"):
			return float(terrain.floor_height(point))
	return 0.0

func _point(angle: float, radius: float, lift: float) -> Vector3:
	var offset := Vector2.from_angle(angle) * radius
	return Vector3(offset.x, _height(center_world + offset) + lift, offset.y)

func _annulus(inner_radius: float, outer_radius: float, lift: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(SEGMENTS):
		var first := float(index) * TAU / SEGMENTS
		var second := float(index + 1) * TAU / SEGMENTS
		var a := _point(first, inner_radius, lift)
		var b := _point(first, outer_radius, lift)
		var c := _point(second, outer_radius, lift)
		var d := _point(second, inner_radius, lift)
		for vertex in [a, b, c, a, c, d]:
			surface.set_normal(Vector3.UP)
			surface.add_vertex(vertex)
	return surface.commit()
