extends SceneTree
## Optional, repeatable editor scene export. This does not alter main.tscn.
## Run: godot --headless --path battlefield_hd2d --script
## res://assets/terrain/bake_environment.gd
const OUTPUT := "res://assets/terrain/battlefield_environment.tscn"

func _initialize() -> void:
	call_deferred("_bake")

func _bake() -> void:
	var terrain: Node3D = load("res://terrain_hd.gd").new()
	# Preserve individually named meshes with their child collision shapes.
	# The runtime sample still uses material batching for performance.
	terrain.batch_geometry = false
	root.add_child(terrain)
	terrain.build()
	terrain.name = "BattlefieldRuinsEnvironment"
	terrain.set_meta("arena_xz", terrain.arena)
	terrain.set_meta("gameplay_obstacles_xz", terrain.obstacles)
	terrain.set_meta("projectile_obstacles_xz", terrain.projectile_obstacles)
	terrain.set_meta("bridges_xz", terrain.bridges)
	terrain.set_meta("source", "Authored 3D terrain, original masonry/path tiles, newly drawn vegetation cutouts and quiet ground")
	if is_instance_valid(terrain.vegetation):
		terrain.vegetation.set_script(null)
	terrain.set_meta("editing_note", "Static editor scene only. Runtime main uses terrain_hd.gd; do not instance both environments together.")
	_own_children(terrain,terrain)
	# A plain Node3D scene has no automatic build step and cannot duplicate itself.
	terrain.set_script(null)
	var packed := PackedScene.new()
	var code := packed.pack(terrain)
	if code == OK:
		code = ResourceSaver.save(packed,OUTPUT)
	if code != OK:
		push_error("Terrain bake failed: " + str(code))
		quit(1)
		return
	print("BAKED " + OUTPUT + " with " + str(terrain.find_children("*","",true,false).size()) + " owned descendants")
	quit(0)

func _own_children(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own_children(child,owner_node)
