extends SceneTree

func _initialize() -> void:
	call_deferred("_test")

func _test() -> void:
	var scene: PackedScene = load("res://assets/terrain/battlefield_environment.tscn")
	var environment: Node3D = scene.instantiate()
	root.add_child(environment)
	var failures: Array[String] = []
	var meshes := environment.find_children("*","MeshInstance3D",true,false)
	var bodies := environment.find_children("*","StaticBody3D",true,false)
	var descendants := environment.find_children("*","",true,false)
	if environment.get_script() != null:
		failures.append("Baked root should not contain a runtime build script")
	for child in descendants:
		if child.owner != environment:
			failures.append("Unowned baked child: "+str(child.name))
	if meshes.size()<100 or bodies.size()<20:
		failures.append("Missing editable terrain geometry/collision")
	await physics_frame
	await physics_frame
	var positions := [Vector2(0,2),Vector2(8.5,2),Vector2(0,-0.1),Vector2(0,4.1),Vector2(5,2),Vector2(-20,2),Vector2(8,-3)]
	var expected := [0.16,0.16,0.16/3.0,0.16/3.0,-2.1,0.0,0.0]
	for i in range(positions.size()):
		var sample: Vector2 = positions[i]
		var query := PhysicsRayQueryParameters3D.create(Vector3(sample.x,6,sample.y),Vector3(sample.x,-4,sample.y),1)
		var hit: Dictionary = environment.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or absf(hit.position.y-expected[i])>0.025:
			failures.append("Baked physical floor mismatch at "+str(sample))
	var report := {"failures":failures,"editable_meshes":meshes.size(),"static_bodies":bodies.size(),"owned_descendants":descendants.size(),"root_is_plain_Node3D":environment.get_script()==null}
	print(JSON.stringify(report))
	var file := FileAccess.open("res://assets/terrain/baked_qa_results.json",FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(report,"\t")+"\n")
	quit(0 if failures.is_empty() else 1)
