extends SceneTree
## Real InputEventJoypad* events pass through Godot InputMap and viewport dispatch.
## This is synthetic engine integration, not a physical-controller hardware claim.
const BattleInput = preload("res://large/core/battle_input.gd")

class InputProbe:
	extends "res://large/core/main.gd"
	var flash_calls := 0
	var restart_calls := 0
	var simulated_time := 0.0
	func _ready() -> void:
		set_process(false)
	func _draw() -> void: pass
	func simulate(dt: float) -> void: simulated_time += dt
	func reset_game() -> void:
		restart_calls += 1
		state = "play"
	func cast_holy_flash() -> void: flash_calls += 1

var game
var passes := 0
var failures: Array[String] = []
var samples: Dictionary = {}

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	if ok:
		passes += 1
		print("PASS ", label)
	else:
		failures.append(label)
		push_error("FAIL " + label)

func emit(event: InputEvent) -> void:
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func button(index: JoyButton, pressed: bool = true, device: int = 0) -> void:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = index
	event.pressed = pressed
	emit(event)

func tap(index: JoyButton, device: int = 0) -> void:
	button(index, true, device)
	button(index, false, device)

func axis(index: JoyAxis, value: float, device: int = 0) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = index
	event.axis_value = value
	emit(event)

func key(code: Key, pressed: bool = true, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	event.echo = echo
	emit(event)

func key_tap(code: Key) -> void:
	key(code)
	key(code, false)

func neutral() -> void:
	for device in [0, 3]:
		axis(JOY_AXIS_LEFT_X, 0.0, device)
		axis(JOY_AXIS_LEFT_Y, 0.0, device)
		for index in [JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN]:
			button(index, false, device)
	for code in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]: key(code, false)

func mode(value: String) -> void:
	neutral()
	game.state = value
	game._sync_input_state()

func test_movement() -> void:
	mode("play")
	axis(JOY_AXIS_LEFT_X, 0.1)
	check(game.controls.movement() == Vector2.ZERO, "Stick drift at 0.10 is inside the radial deadzone")
	axis(JOY_AXIS_LEFT_X, 0.15)
	axis(JOY_AXIS_LEFT_Y, 0.15)
	check(game.controls.movement() == Vector2.ZERO, "Diagonal drift remains inside the circular 0.22 deadzone")
	axis(JOY_AXIS_LEFT_Y, 0.0)
	axis(JOY_AXIS_LEFT_X, 0.61)
	var half: Vector2 = game.controls.movement()
	check(half.is_equal_approx(Vector2(0.5, 0.0)), "0.61 analog input remaps to half-speed, not normalized full speed")
	axis(JOY_AXIS_LEFT_X, 1.0)
	check(game.controls.movement().is_equal_approx(Vector2.RIGHT), "Full stick reaches the existing unit movement speed")
	axis(JOY_AXIS_LEFT_Y, 1.0)
	check(is_equal_approx(game.controls.movement().length(), 1.0), "Full diagonal stick never moves faster than cardinal input")
	neutral()
	button(JOY_BUTTON_DPAD_LEFT)
	check(game.controls.movement().is_equal_approx(Vector2.LEFT), "D-pad generates real left movement through InputMap")
	button(JOY_BUTTON_DPAD_UP)
	check(game.controls.movement().is_equal_approx(Vector2(-1, -1).normalized()), "D-pad diagonal is normalized without a speed boost")
	neutral()
	key(KEY_D)
	key(KEY_W)
	check(game.controls.movement().is_equal_approx(Vector2(1, -1).normalized()), "Physical WASD input remains active alongside controller actions")
	neutral()
	axis(JOY_AXIS_LEFT_X, -0.61, 3)
	check(game.controls.movement().is_equal_approx(Vector2(-0.5, 0)), "A pad on a nonzero device ID is supported")
	neutral()
	check(game.controls.movement() == Vector2.ZERO, "Release/centering clears movement without stale input")
	samples["half_stick_vector"] = [half.x, half.y]

func test_state_controls() -> void:
	mode("title")
	tap(JOY_BUTTON_A)
	check(game.state == "play", "A starts from title through actual joypad event dispatch")
	tap(JOY_BUTTON_START)
	check(game.state == "pause", "Start opens pause")
	var before: float = game.simulated_time
	game._process(0.05)
	check(game.simulated_time == before, "Pause prevents authoritative simulation advancement")
	tap(JOY_BUTTON_A)
	check(game.state == "play", "A resumes the paused game")
	tap(JOY_BUTTON_B)
	check(game.state == "pause", "B pauses play as a consistent Back action")
	tap(JOY_BUTTON_B)
	check(game.state == "play", "B returns from pause")
	tap(JOY_BUTTON_BACK)
	check(game.state == "map", "View/Back opens the tactical map")
	tap(JOY_BUTTON_B)
	check(game.state == "play", "B closes the tactical map")
	tap(JOY_BUTTON_START)
	tap(JOY_BUTTON_BACK)
	check(game.state == "map", "The map can also be inspected from pause")
	tap(JOY_BUTTON_BACK)
	check(game.state == "pause", "Closing a map opened from pause preserves the paused state")
	var restarts: int = game.restart_calls
	tap(JOY_BUTTON_Y)
	check(game.restart_calls == restarts + 1 and game.state == "play", "Y explicitly restarts from pause")
	for result in ["win", "lose"]:
		mode(result)
		restarts = game.restart_calls
		tap(JOY_BUTTON_A)
		check(game.restart_calls == restarts + 1 and game.state == "play", "A restarts from " + result)
	mode("title")
	key_tap(KEY_ENTER)
	check(game.state == "play", "Existing Enter title shortcut is preserved")
	key_tap(KEY_ESCAPE)
	check(game.state == "pause", "Existing Escape pause shortcut is preserved")
	key(KEY_ESCAPE, true, true)
	check(game.state == "pause", "Keyboard auto-repeat cannot toggle pause repeatedly")
	key(KEY_ESCAPE, false)
	key_tap(KEY_ESCAPE)
	key_tap(KEY_TAB)
	check(game.state == "map", "Existing Tab map shortcut is preserved")
	key_tap(KEY_ESCAPE)
	check(game.state == "play", "Existing Escape closes a map opened during play")

func test_upgrade_navigation() -> void:
	mode("upgrade")
	check(game.upgrade_selection == 0, "Upgrade opens with a visible first-card selection")
	tap(JOY_BUTTON_DPAD_RIGHT)
	check(game.upgrade_selection == 1, "D-pad moves upgrade selection once per press")
	tap(JOY_BUTTON_DPAD_RIGHT)
	check(game.upgrade_selection == 2, "Repeated D-pad presses can reach the third card")
	tap(JOY_BUTTON_DPAD_RIGHT)
	check(game.upgrade_selection == 0, "Upgrade navigation wraps through all three cards")
	axis(JOY_AXIS_LEFT_X, 0.8)
	check(game.upgrade_selection == 1, "Left stick selects the next upgrade at the menu threshold")
	game._process(0.05)
	check(game.upgrade_selection == 1, "Held stick does not race through cards each frame")
	for _i in range(6): game._process(0.05)
	check(game.upgrade_selection == 2, "Held stick repeats only after its initial navigation delay")
	axis(JOY_AXIS_LEFT_X, 0.0)
	var max_before: float = game.max_hp
	tap(JOY_BUTTON_A)
	check(game.state == "play" and is_equal_approx(game.max_hp, max_before + 15), "A confirms the highlighted third upgrade exactly once")
	mode("upgrade")
	var selection: int = game.upgrade_selection
	axis(JOY_AXIS_LEFT_X, 0.4)
	for _i in range(20): game._process(0.05)
	check(game.upgrade_selection == selection, "Subthreshold stick noise never navigates an upgrade")
	neutral()
	var before: float = game.simulated_time
	tap(JOY_BUTTON_B)
	tap(JOY_BUTTON_START)
	game._process(0.05)
	check(game.state == "upgrade" and game.simulated_time == before, "Back/Start cannot skip a mandatory upgrade or unpause combat")
	key_tap(KEY_RIGHT)
	check(game.upgrade_selection == 1, "Arrow keys can navigate highlighted upgrades")
	var rate_before: float = game.attack_rate
	key_tap(KEY_ENTER)
	check(game.state == "play" and game.attack_rate < rate_before, "Enter confirms keyboard-highlighted upgrade")
	mode("upgrade")
	var damage_before: float = game.damage
	key_tap(KEY_1)
	check(game.state == "play" and game.damage == damage_before + 9, "Existing 1/2/3 direct upgrade shortcuts remain supported")
	mode("play")
	axis(JOY_AXIS_LEFT_X, 1.0)
	game.state = "upgrade"
	game._sync_input_state()
	for _i in range(10): game._process(0.05)
	check(game.upgrade_selection == 0, "Movement held when a level-up opens cannot silently change its selection")
	axis(JOY_AXIS_LEFT_X, 0.0)
	axis(JOY_AXIS_LEFT_X, 1.0)
	check(game.upgrade_selection == 1, "After centering, the stick navigates the new upgrade normally")
	neutral()

func click(position: Vector2) -> void:
	# Headless windows may be 64x64; emit at the transformed physical position.
	position = root.get_final_transform() * position
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = true
	emit(event)
	event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = false
	emit(event)

func test_mouse_and_prompt_bounds() -> void:
	mode("title")
	click(Vector2(300, 560))
	check(game.state == "play", "Mouse title start is preserved")
	mode("lose")
	var restarts: int = game.restart_calls
	click(Vector2(500, 500))
	check(game.restart_calls == restarts + 1, "Mouse end-screen restart is preserved")
	mode("upgrade")
	click(Vector2(480, 400))
	check(game.state == "upgrade", "Clicking the gap between upgrade cards cannot accidentally buy one")
	click(Vector2(145, 400))
	check(game.state == "upgrade", "Clicking outside upgrade cards cannot select the first card")
	var rate: float = game.attack_rate
	click(Vector2(600, 400))
	check(game.state == "play" and game.attack_rate < rate, "Mouse can still choose the second upgrade directly")
	var ui_font = load("res://assets/interface.ttf")
	var fit := true
	for record in [
		[24, 660, "Enter / 点击开始    20分钟战场 · 营救、清军团、决战"],
		[24, 660, "A / Start 开始    20分钟战场 · 营救、清军团、决战"],
		[21, 960, "战斗已暂停 · 1 / 2 / 3、点击或左右 + Enter"],
		[21, 960, "战斗已暂停 · 左摇杆 / 十字键左右选择，A 确认"],
		[25, 390, "R / Enter / 点击，再次集结"],
		[13, 360, "X/RB 圣闪 · View 地图 · Start 暂停"],
		[19, 980, "升级：1 / 2 / 3 或左右 + Enter · ESC 暂停 · Tab 地图 · M 静音"],
		[19, 980, "左摇杆 / 十字键移动 · 自动挥刀 · X / RB 圣闪 · 清围后靠近营救"]]:
		fit = fit and ui_font.get_string_size(record[2], HORIZONTAL_ALIGNMENT_LEFT, -1, record[0]).x <= record[1]
	check(fit, "New keyboard/controller prompt widths fit the existing panels with the production font")

func test_ability_and_prompts() -> void:
	mode("play")
	var calls: int = game.flash_calls
	tap(JOY_BUTTON_X)
	tap(JOY_BUTTON_RIGHT_SHOULDER)
	key_tap(KEY_Q)
	check(game.flash_calls == calls + 3, "X, RB, and Q invoke the HolyFlash interface once each")
	for state in ["title", "pause", "map", "upgrade", "win", "lose"]:
		mode(state)
		calls = game.flash_calls
		tap(JOY_BUTTON_X)
		tap(JOY_BUTTON_RIGHT_SHOULDER)
		key_tap(KEY_Q)
		check(game.flash_calls == calls, "HolyFlash is gated outside combat: " + state)
	mode("play")
	tap(JOY_BUTTON_X)
	check(game.controls.prompt("keyboard", "controller") == "controller", "Prompts switch when a controller is used")
	key_tap(KEY_Q)
	check(game.controls.prompt("keyboard", "controller") == "keyboard", "Prompts return to keyboard after keyboard activity")
	axis(JOY_AXIS_LEFT_X, 0.05)
	check(not game.controls.using_gamepad, "Stick drift does not steal keyboard prompts")
	neutral()

func test_real_logic_movement() -> void:
	game.queue_free()
	await process_frame
	game = load("res://large/battle_logic.gd").new()
	root.add_child(game)
	game.set_process(false)
	game.audio_controller.settings_path = ""
	game.set_volume(0)
	game.demo = false
	game.state = "play"
	game._sync_input_state()
	game.attack_cd = 9999
	game.spawn_cd = 9999
	game.needed = 1000000
	game.hero = game.START_POSITION
	var origin: Vector2 = game.hero
	axis(JOY_AXIS_LEFT_X, 0.61)
	game.simulate(0.05)
	var half_distance: float = origin.distance_to(game.hero)
	neutral()
	game.hero = origin
	axis(JOY_AXIS_LEFT_X, 1.0)
	game.simulate(0.05)
	var full_distance: float = origin.distance_to(game.hero)
	check(absf(half_distance - 5.125) < 0.02 and absf(full_distance - 10.25) < 0.02, "Real battle simulation preserves half/full analog displacement at 205 px/s")
	check(game.hero_moving and game.facing.is_equal_approx(Vector2.RIGHT), "Analog movement retains normalized facing for attacks and follow direction")
	neutral()
	tap(JOY_BUTTON_START)
	var snapshot := {"hero": game.hero, "time": game.time, "sources": game.corpse_field.total_consumed, "hp": game.hp}
	for _i in range(5): game._process(0.05)
	check(game.state == "pause" and game.hero == snapshot.hero and game.time == snapshot.time and game.hp == snapshot.hp and game.corpse_field.total_consumed == snapshot.sources, "Controller pause freezes actual movement, combat time, HP, and spawn consumption")
	check(game.audio_controller.paused, "Controller pause immediately pauses the real audio controller")
	tap(JOY_BUTTON_START)
	check(game.state == "play" and not game.audio_controller.paused, "Controller resume immediately restores real audio state")
	tap(JOY_BUTTON_BACK)
	check(game.state == "map" and game.audio_controller.paused, "Controller tactical map pauses actual audio and simulation")
	tap(JOY_BUTTON_BACK)
	game.xp = game.needed
	game._process(0.01)
	check(game.state == "upgrade" and game.audio_controller.paused, "An actual XP level-up freezes battle/audio in the same frame")
	tap(JOY_BUTTON_DPAD_RIGHT)
	tap(JOY_BUTTON_A)
	check(game.state == "play" and not game.audio_controller.paused, "Controller completes a real XP upgrade and resumes battle/audio")
	samples["actual_half_speed_displacement"] = half_distance
	samples["actual_full_speed_displacement"] = full_distance
	neutral()

func run() -> void:
	Input.use_accumulated_input = false
	game = InputProbe.new()
	root.add_child(game)
	test_movement()
	test_state_controls()
	test_upgrade_navigation()
	test_mouse_and_prompt_bounds()
	test_ability_and_prompts()
	await test_real_logic_movement()
	var output := {"passes": passes, "failures": failures, "samples": samples,
		"scope": "Godot synthetic InputMap events plus actual battle_logic integration",
		"hardware_validation": "No physical gamepad attached; USB/Bluetooth mapping and native hardware are not certified"}
	var report := FileAccess.open("res://large/qa/gamepad_input_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify(output, "\t"))
	report.close()
	print("GAMEPAD_INPUT_RESULT ", JSON.stringify(output))
	game.audio_controller.stop_effects()
	game.music.stop()
	game.music.stream = null
	await create_timer(0.15).timeout
	game.queue_free()
	await process_frame
	await create_timer(0.15).timeout
	quit(0 if failures.is_empty() else 1)
