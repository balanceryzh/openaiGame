extends RefCounted
## One action map for keyboard, standard Godot-mapped pads, and UI navigation.
## No OS key emulation: Input.get_vector preserves the analog stick magnitude.
const MOVE_LEFT := "battle_move_left"
const MOVE_RIGHT := "battle_move_right"
const MOVE_UP := "battle_move_up"
const MOVE_DOWN := "battle_move_down"
const CONFIRM := "battle_confirm"
const BACK := "battle_back"
const PAUSE := "battle_pause"
const MAP := "battle_map"
const RESTART := "battle_restart"
const HOLY_FLASH := "battle_holy_flash"
const DEADZONE := 0.22
const MENU_PRESS := 0.55
const MENU_RELEASE := 0.30
const MENU_INITIAL_DELAY := 0.32
const MENU_REPEAT_DELAY := 0.14

var using_gamepad := false
var _menu_direction := 0
var _menu_wait := 0.0
var _menu_needs_neutral := false

func _init() -> void:
	install_actions()
	using_gamepad = not Input.get_connected_joypads().is_empty()

func install_actions() -> void:
	_bind(MOVE_LEFT, [_key(KEY_A, true), _key(KEY_LEFT, true), _axis(JOY_AXIS_LEFT_X, -1.0), _button(JOY_BUTTON_DPAD_LEFT)])
	_bind(MOVE_RIGHT, [_key(KEY_D, true), _key(KEY_RIGHT, true), _axis(JOY_AXIS_LEFT_X, 1.0), _button(JOY_BUTTON_DPAD_RIGHT)])
	_bind(MOVE_UP, [_key(KEY_W, true), _key(KEY_UP, true), _axis(JOY_AXIS_LEFT_Y, -1.0), _button(JOY_BUTTON_DPAD_UP)])
	_bind(MOVE_DOWN, [_key(KEY_S, true), _key(KEY_DOWN, true), _axis(JOY_AXIS_LEFT_Y, 1.0), _button(JOY_BUTTON_DPAD_DOWN)])
	_bind(CONFIRM, [_key(KEY_ENTER), _key(KEY_KP_ENTER), _button(JOY_BUTTON_A)])
	_bind(BACK, [_key(KEY_ESCAPE), _button(JOY_BUTTON_B)])
	_bind(PAUSE, [_button(JOY_BUTTON_START)])
	_bind(MAP, [_key(KEY_TAB), _button(JOY_BUTTON_BACK)])
	_bind(RESTART, [_key(KEY_R), _button(JOY_BUTTON_Y)])
	_bind(HOLY_FLASH, [_key(KEY_Q), _button(JOY_BUTTON_X), _button(JOY_BUTTON_RIGHT_SHOULDER)])

func _bind(action: StringName, events: Array) -> void:
	if not InputMap.has_action(action): InputMap.add_action(action, DEADZONE)
	for event in events:
		if not InputMap.action_has_event(action, event): InputMap.action_add_event(action, event)

func _key(code: Key, physical: bool = false) -> InputEventKey:
	var event := InputEventKey.new()
	if physical: event.physical_keycode = code
	else: event.keycode = code
	return event

func _button(code: JoyButton) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.device = -1
	event.button_index = code
	return event

func _axis(code: JoyAxis, direction: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.device = -1
	event.axis = code
	event.axis_value = direction
	return event

func movement() -> Vector2:
	# Godot performs a circular deadzone, then remaps [deadzone, 1] to [0, 1].
	# Diagonal keyboard/D-pad input is capped to unit length by the same path.
	return Input.get_vector(MOVE_LEFT, MOVE_RIGHT, MOVE_UP, MOVE_DOWN, DEADZONE)

func observe_event(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.pressed:
		using_gamepad = true
	elif event is InputEventJoypadMotion and absf(event.axis_value) > DEADZONE:
		using_gamepad = true
	elif event is InputEventKey and event.pressed:
		using_gamepad = false
	elif event is InputEventMouseButton and event.pressed:
		using_gamepad = false
	elif event is InputEventMouseMotion and event.relative.length_squared() > 4.0:
		using_gamepad = false

func prompt(keyboard: String, gamepad: String) -> String:
	return gamepad if using_gamepad else keyboard

func reset_menu_navigation(require_neutral: bool = false) -> void:
	_menu_direction = 0
	_menu_wait = 0.0
	_menu_needs_neutral = require_neutral and absf(_menu_axis()) > MENU_RELEASE

func _menu_axis() -> float:
	return Input.get_action_raw_strength(MOVE_RIGHT) - Input.get_action_raw_strength(MOVE_LEFT)

func menu_horizontal_step(dt: float) -> int:
	var axis := _menu_axis()
	if absf(axis) <= MENU_RELEASE:
		reset_menu_navigation()
		return 0
	if _menu_needs_neutral: return 0
	var direction := 1 if axis > 0.0 else -1
	if direction != _menu_direction:
		if absf(axis) < MENU_PRESS: return 0
		_menu_direction = direction
		_menu_wait = MENU_INITIAL_DELAY
		return direction
	_menu_wait -= maxf(0.0, dt)
	if _menu_wait <= 0.0:
		_menu_wait = MENU_REPEAT_DELAY
		return direction
	return 0
