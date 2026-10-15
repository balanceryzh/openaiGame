extends SceneTree
## Real scene integration and 3D node lifecycle, not a rendered visual review.
var passed := 0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("PASS ", label)
	else:
		failures.append(label)
		push_error("FAIL " + label)
func run() -> void:
	var scene = load("res://large/main.tscn").instantiate()
	root.add_child(scene)
	scene.set_process(false)
	var game = scene.logic
	game.set_process(false)
	game.state = "play"
	game.audio_controller.settings_path = ""
	game.audio_controller.set_volume(0.0)
	var victim: Dictionary = game.make_enemy(game.hero + Vector2(140, 0), "undead")
	victim.p = game.hero + Vector2(140, 0)
	victim.hp = 120.0
	victim.max = 120.0
	check(game.cast_holy_flash() and victim.hp == 70.0, "Real large/main.tscn casts Holy Flash through its authoritative logic")
	var effect = game.holy_flash_effect
	check(is_instance_valid(effect) and effect.get_parent() == scene and effect.visible, "Holy Flash attaches visible native 3D geometry to the actual battlefield root")
	check(effect.get_child_count() == 4 and effect.perimeter.mesh.get_surface_count() == 1 and effect.wave.mesh.get_surface_count() == 1, "Perimeter, wave, ground light and hero column all have real 3D meshes")
	check(effect.perimeter_material.albedo_color.a > 0 and effect.wave_material.albedo_color.a > 0, "Gold-white range and expanding wave begin visible")
	var before: float = effect.elapsed
	game.state = "pause"
	game._process(0.05)
	scene._process(0.05)
	check(effect.elapsed == before and game.holy_flash_cooldown == 10.0, "Real scene presentation cannot independently advance paused ability time")
	game.reset_game()
	scene._process(0.0)
	check(not effect.visible and game.holy_flash_cooldown == 0.0, "Real restart and terrain rebind leave no stale flash")
	for _cast in range(20):
		game.holy_flash_cooldown = 0.0
		game.cast_holy_flash()
	check(game.holy_flash_effect == effect and effect.get_child_count() == 4, "Repeated casts reuse one bounded effect instead of accumulating world nodes")
	game.simulate(0.72)
	check(not effect.visible, "Completed real simulation flash is hidden after 0.72 seconds")
	var output := {"passed": passed, "failures": failures, "scope": "Actual main scene / terrain / 3D meshes and lifecycle, headless only; appearance not visually certified"}
	var report := FileAccess.open("res://large/qa/holy_flash_scene_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify(output, "\t"))
	report.close()
	print("HOLY_FLASH_SCENE_QA ", JSON.stringify(output))
	game.audio_controller.stop_effects()
	game.music.stop()
	game.music.stream = null
	await create_timer(0.18).timeout
	scene.queue_free()
	await process_frame
	await create_timer(0.18).timeout
	quit(0 if failures.is_empty() else 1)
