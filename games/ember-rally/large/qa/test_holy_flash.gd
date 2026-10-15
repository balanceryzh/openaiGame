extends SceneTree
## Run: godot --headless --path . --script large/qa/test_holy_flash.gd
## Production hit/death/reward path; explicit 120 HP fixtures measure exact damage.
const Logic = preload("res://large/battle_logic.gd")
class TestTerrain extends RefCounted:
	func floor_height(point: Vector2) -> float: return sin(point.x * 0.07) * 0.2
class TestView extends Node3D:
	var terrain := TestTerrain.new()
var game
var adapter: TestView
var passed := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS ", label)
	else:
		failures.append(label)
		push_error("FAIL " + label)

func fixture() -> void:
	game.reset_game()
	game.set_process(false)
	game.demo = false
	game.audio_controller.settings_path = ""
	game.audio_controller.set_volume(0.0)
	game.hero = Vector2(3700.0, 2750.0)
	game.enemies.clear()
	game.sleeping_enemies.clear()
	game.allies.clear()
	game.camps.clear()
	game.corpses.clear()
	game.gems.clear()
	game.bullets.clear()
	game.attack_cd = 9999.0
	game.spawn_cd = 9999.0
	game.necromancers.spawn_cooldown = 9999.0
	game.director.entrance_cooldown = 9999.0
	game.needed = 1000000
	game.holy_flash_cooldown_seconds = 10.0

func enemy_at(offset: Vector2, kind: String = "undead", health: float = 120.0) -> Dictionary:
	var enemy: Dictionary = game.make_enemy(game.hero + offset, kind)
	# Exact synthetic geometry is intentional: terrain must not shift boundary cases.
	enemy.p = game.hero + offset
	enemy.hp = health
	enemy.max = health
	return enemy

func test_radius_and_taxonomy() -> void:
	fixture()
	var inside: Array[Dictionary] = []
	for offset in [Vector2.ZERO, Vector2(499.99, 0), Vector2(500, 0), Vector2(-500, 0), Vector2(0, 500), Vector2(300, 400)]:
		inside.append(enemy_at(offset))
	inside[0].visual_kind = "undead"
	inside[1].visual_kind = "zombie"
	inside[1].headgear_variant = "retained"
	inside[2].visual_kind = "zombie"
	inside[2].headgear_variant = "fallen"
	inside[3].rise_elapsed = 0.25
	inside[3].rise_duration = 1.5
	var outside: Array[Dictionary] = []
	for offset in [Vector2(500.01, 0), Vector2(-500.01, 0), Vector2(0, 500.01), Vector2(300.01, 400), Vector2(9000, 0)]:
		outside.append(enemy_at(offset))
	var excluded: Array[Dictionary] = []
	for kind in ["demon", "caster", "boss"]:
		excluded.append(enemy_at(Vector2(25, 0), kind))
	var mud := enemy_at(Vector2(50, 0))
	mud.visual_kind = "earth"
	mud.skin_kind = "earth"
	mud.origin = "earth_summon"
	excluded.append(mud)
	var dead := enemy_at(Vector2(60, 0), "undead", 0.0)
	var ally := {"p": game.hero, "kind": "shield", "hp": 110.0, "max": 110.0}
	game.allies.append(ally)
	var hero_hp: float = game.hp
	var source_consumed: int = game.corpse_field.total_consumed
	check(game.HOLY_FLASH_RADIUS_PX == 500.0 and game.HOLY_FLASH_DAMAGE == 50.0, "10 yards = 10 world units = 500 authoritative pixels; damage is fixed at 50")
	check(game.cast_holy_flash(), "Ready living hero can cast Holy Flash")
	check(inside.all(func(enemy): return enemy.hp == 70.0 and enemy.flash == 0.12), "Every living skeleton/zombie at 0–500px inclusive takes exactly 50 and existing hit feedback")
	check(outside.all(func(enemy): return enemy.hp == 120.0 and enemy.flash == 0.0), "Targets 0.01px outside circle and across the map receive zero damage")
	check(excluded.all(func(enemy): return enemy.hp == 120.0), "Demons, casters, bosses and mud constructs are not undead targets")
	check(dead.hp == 0.0 and ally.hp == 110.0 and game.hp == hero_hp, "Dead enemies, allied fighters and the hero remain unchanged")
	check(game.holy_flash_last_hits == inside.size() and game.corpse_field.total_consumed == source_consumed, "Only actual undead actors count; dormant corpse sources are not consumed or revived")
	check(not game.cast_holy_flash() and inside[0].hp == 70.0 and game.holy_flash_cast_count == 1, "Repeated input during cooldown never deals duplicate damage or restarts the flash")

func test_death_and_sleeping() -> void:
	fixture()
	var victim := enemy_at(Vector2(70, 0), "undead", 48.0)
	victim.corpse_id = "holy-flash-source"
	var summon := enemy_at(Vector2(80, 0), "undead", 48.0)
	summon.summoned_by = "test-necromancer"
	var sleeping := enemy_at(Vector2(90, 0), "undead", 48.0)
	game.enemies.erase(sleeping)
	game.sleeping_enemies.append(sleeping)
	var remote := enemy_at(Vector2(2000, 0), "undead", 48.0)
	game.enemies.erase(remote)
	game.sleeping_enemies.append(remote)
	check(game.cast_holy_flash(), "Second fixture casts through the production damage path")
	check(victim.hp == -2.0 and summon.hp == -2.0 and sleeping.hp == -2.0, "Ordinary 48 HP undead take exactly 50 and die, including a nearby dormant actor")
	check(not game.enemies.has(victim) and not game.enemies.has(summon) and not game.sleeping_enemies.has(sleeping), "Kills remove live/dormant combat actors immediately")
	check(game.kills == 3 and game.gems.size() == 2 and game.corpses.size() == 3, "Existing kill, corpse-dissolve and XP rules apply; summoned undead still award zero XP")
	check(game.rewarded_source_ids.has("holy-flash-source") and remote.hp == 48.0, "Source reward ledger is preserved and distant sleeping actors are untouched")
	check(game.corpses.all(func(body): return body.get("disintegrate", false)), "Holy Flash deaths use the existing dissolve lifecycle")

func test_cooldown_pause_and_reset() -> void:
	fixture()
	game.cast_holy_flash()
	var effect: Node3D = game.holy_flash_effect
	check(is_instance_valid(effect) and effect.visible and effect.get_parent() == adapter, "Gold-white effect is a real Node3D attached to the world adapter")
	check(effect.radius_world == 10.0 and effect.center_world == game.hero / 50.0, "Visual center and radius match the authoritative cast exactly")
	var vertices: PackedVector3Array = effect.perimeter.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var maximum_radius := 0.0
	var floor_correct := true
	for vertex in vertices:
		maximum_radius = maxf(maximum_radius, Vector2(vertex.x, vertex.z).length())
		floor_correct = floor_correct and is_equal_approx(vertex.y, adapter.terrain.floor_height(effect.center_world + Vector2(vertex.x, vertex.z)) + 0.095)
	check(is_equal_approx(maximum_radius, 10.0) and floor_correct, "3D perimeter ends exactly at 10 yards and follows terrain height")
	var age: float = effect.elapsed
	for state in ["pause", "map", "upgrade", "title", "win", "lose"]:
		game.state = state
		game.simulate(5.0)
		game._process(0.05)
		check(game.holy_flash_cooldown == 10.0 and effect.elapsed == age and not game.cast_holy_flash(), "%s freezes ability cooldown/flash and blocks casting" % state)
	game.state = "play"
	game.simulate(0.0)
	game.simulate(-1.0)
	check(game.holy_flash_cooldown == 10.0 and effect.elapsed == age, "Zero/negative simulation delta never advances ability time")
	game.simulate(9.9)
	check(is_equal_approx(game.holy_flash_cooldown, 0.1) and not game.cast_holy_flash() and not effect.visible, "9.9 active seconds leave 0.1s cooldown; flash expires without lingering nodes")
	game.simulate(0.1)
	check(game.holy_flash_cooldown == 0.0 and game.cast_holy_flash(), "Exactly 10 active seconds unlock the next cast")
	var count: int = game.holy_flash_cast_count
	game.hp = 0.0
	game.simulate(2.0)
	check(game.holy_flash_cast_count == count and game.holy_flash_cooldown == 10.0 and not game.cast_holy_flash(), "A dead hero cannot cast or advance ability cooldown")
	game.reset_game()
	check(game.holy_flash_cooldown == 0.0 and game.holy_flash_cast_count == 0 and game.holy_flash_last_hits == 0 and not effect.visible, "Restart clears cooldown, hit counters and old visual state")
	game.holy_flash_cooldown_seconds = 3.25
	check(game.cast_holy_flash() and game.holy_flash_cooldown == 3.25, "Cooldown duration remains configurable without changing 50 damage or 10-yard radius")

func emit(event: InputEvent) -> void:
	Input.parse_input_event(event.duplicate())
	Input.flush_buffered_events()

func test_real_input_dispatch() -> void:
	Input.use_accumulated_input = false
	for binding in ["Q", "X", "RB"]:
		fixture()
		var victim := enemy_at(Vector2(150, 0))
		var event: InputEvent
		if binding == "Q":
			event = InputEventKey.new()
			event.keycode = KEY_Q
			event.physical_keycode = KEY_Q
		else:
			event = InputEventJoypadButton.new()
			event.device = 0
			event.button_index = JOY_BUTTON_X if binding == "X" else JOY_BUTTON_RIGHT_SHOULDER
		event.pressed = true
		emit(event)
		check(victim.hp == 70.0 and game.holy_flash_cast_count == 1, "Actual %s engine event dispatch triggers production Holy Flash and exactly 50 damage" % binding)
		emit(event)
		check(victim.hp == 70.0 and game.holy_flash_cast_count == 1, "Repeated %s input during cooldown cannot recast" % binding)
		event.pressed = false
		emit(event)
		game.state = "pause"
		game.holy_flash_cooldown = 0.0
		event.pressed = true
		emit(event)
		check(victim.hp == 70.0 and game.holy_flash_cast_count == 1, "%s cannot cast in the pause menu even with cooldown ready" % binding)
		event.pressed = false
		emit(event)
	fixture()
	var victim := enemy_at(Vector2(150, 0))
	var echo := InputEventKey.new()
	echo.keycode = KEY_Q
	echo.physical_keycode = KEY_Q
	echo.pressed = true
	echo.echo = true
	emit(echo)
	check(victim.hp == 120.0 and game.holy_flash_cast_count == 0, "Keyboard autorepeat does not trigger a new cast")
	var terrain_before = game.terrain
	var selected_track: int = game.audio_controller.selected_track
	var spawn_clock: float = game.spawn_cd
	var wave_clock: float = game.time
	game.cast_holy_flash()
	check(game.terrain == terrain_before and game.audio_controller.selected_track == selected_track and game.spawn_cd == spawn_clock and game.time == wave_clock, "Casting does not replace terrain, music, wave clock or spawn timer")

func run() -> void:
	adapter = TestView.new()
	root.add_child(adapter)
	game = Logic.new()
	game.view_adapter = adapter
	adapter.add_child(game)
	game.set_process(false)
	test_radius_and_taxonomy()
	test_death_and_sleeping()
	test_cooldown_pause_and_reset()
	test_real_input_dispatch()
	var output := {"passed": passed, "failures": failures, "radius_px": 500, "damage": 50, "default_cooldown_seconds": 10, "earth_construct_excluded": true, "scope": "Production damage/cooldown/reset/mesh and synthetic Godot Q/X/RB event dispatch; native rendering and physical gamepad not certified"}
	var report := FileAccess.open("res://large/qa/holy_flash_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify(output, "\t"))
	report.close()
	print("HOLY_FLASH_QA ", JSON.stringify(output))
	game.audio_controller.stop_effects()
	game.music.stop()
	game.music.stream = null
	await create_timer(0.18).timeout
	adapter.queue_free()
	await process_frame
	game = null
	adapter = null
	await create_timer(0.18).timeout
	quit(0 if failures.is_empty() else 1)
