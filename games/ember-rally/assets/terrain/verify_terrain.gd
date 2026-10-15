extends SceneTree
class FakeGameClock extends Node:
	var elapsed := 0.0
func _initialize() -> void:
	call_deferred("_test")
func _test() -> void:
	var terrain: Node3D = load("res://terrain_hd.gd").new()
	root.add_child(terrain)
	var game_clock := FakeGameClock.new()
	root.add_child(game_clock)
	terrain.build(game_clock)
	var failures: Array[String] = []
	for start in [Vector2(0,10),Vector2(8,-3),Vector2(0,2),Vector2(8.5,2),Vector2(-20,2)]:
		if not terrain.is_free(start,0.4):
			failures.append("Spawn/path blocked: "+str(start))
	var point := Vector2(0,10)
	for target in [Vector2(0,-3),Vector2(8,-3)]:
		for step in range(200):
			point = terrain.move_safe(point,point.move_toward(target,0.13),0.4)
		if point.distance_to(target)>0.01:
			failures.append("Could not reach: "+str(target))
	for x in [-13.0,-8.0,4.0,12.0,18.0]:
		var stopped: Vector2 = terrain.move_safe(Vector2(x,6),Vector2(x,-2),0.4)
		if stopped.y < 3.85:
			failures.append("Crossed pit at "+str(x))
	for bridge_x in [0.0,8.5]:
		if absf(terrain.floor_height(Vector2(bridge_x,2))-0.16)>0.0001:
			failures.append("Incorrect bridge top")
	if absf(terrain.floor_height(Vector2(5,2))+2.1)>0.0001:
		failures.append("Missing trench depth")
	# Raycasts check the helper against actual StaticBody3D floor collision.
	await physics_frame
	await physics_frame
	for sample in [Vector2(0,2),Vector2(8.5,2),Vector2(0,-0.1),Vector2(0,4.1),Vector2(5,2),Vector2(-20,2),Vector2(8,-3)]:
		var query := PhysicsRayQueryParameters3D.create(Vector3(sample.x,6,sample.y),Vector3(sample.x,-4,sample.y),1)
		var hit: Dictionary = terrain.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			failures.append("No physical floor at "+str(sample))
		elif absf(hit.position.y-terrain.floor_height(sample)) > 0.025:
			failures.append("Floor helper/physics mismatch at "+str(sample))
	# Decorative motion follows gameplay time, including pause/end and retry.
	game_clock.elapsed = 7.25
	terrain._process(0.0)
	for mat in terrain._animated_ground_materials:
		if not is_equal_approx(float(mat.get_shader_parameter("game_clock")),7.25):
			failures.append("Decorative shader missed gameplay clock")
	terrain._process(25.0)
	for mat in terrain._animated_ground_materials:
		if not is_equal_approx(float(mat.get_shader_parameter("game_clock")),7.25):
			failures.append("Decorative shader advanced while gameplay clock paused")
	game_clock.elapsed = 0.0
	terrain._process(0.0)
	for mat in terrain._animated_ground_materials:
		if not is_zero_approx(float(mat.get_shader_parameter("game_clock"))):
			failures.append("Decorative shader missed retry clock reset")
	var report := {"failures":failures,"obstacles":terrain.obstacles.size(),"projectile_obstacles":terrain.projectile_obstacles.size(),"root_nodes_after_batch":terrain.get_child_count(),"physical_floor_raycast_samples":7,"animation_clock_checks":3,"animated_materials":terrain._animated_ground_materials.size()}
	print(JSON.stringify(report))
	var file := FileAccess.open("res://assets/terrain/runtime_qa_results.json",FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(report,"\t")+"\n")
	quit(0 if failures.is_empty() else 1)
