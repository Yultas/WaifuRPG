class_name HeroInput
extends RefCounted
## Programmatic InputMap registration for hero controls, so project.godot stays
## untouched. Defaults follow docs/gdd/03_combat.md: WASD + left stick to move,
## ЛКМ attack, ПКМ skill, Space dash (B/circle on gamepad), 1/2/3 direct swap,
## D-pad up/down cycles the party. Defaults are only added to actions that have no
## events, so a settings screen can rebind them through InputMap.


const MOVE_LEFT := &"hero_move_left"
const MOVE_RIGHT := &"hero_move_right"
const MOVE_UP := &"hero_move_up"
const MOVE_DOWN := &"hero_move_down"
const ATTACK := &"hero_attack"
const SKILL := &"hero_skill"
const DASH := &"hero_dash"
const SWAP_1 := &"hero_swap_1"
const SWAP_2 := &"hero_swap_2"
const SWAP_3 := &"hero_swap_3"
const SWAP_NEXT := &"hero_swap_next"
const SWAP_PREV := &"hero_swap_prev"


static func register() -> void:
	_add_action(MOVE_LEFT, [_key(KEY_A), _joy_axis(JOY_AXIS_LEFT_X, -1.0)])
	_add_action(MOVE_RIGHT, [_key(KEY_D), _joy_axis(JOY_AXIS_LEFT_X, 1.0)])
	_add_action(MOVE_UP, [_key(KEY_W), _joy_axis(JOY_AXIS_LEFT_Y, -1.0)])
	_add_action(MOVE_DOWN, [_key(KEY_S), _joy_axis(JOY_AXIS_LEFT_Y, 1.0)])
	_add_action(ATTACK, [_mouse_button(MOUSE_BUTTON_LEFT), _joy_button(JOY_BUTTON_X)])
	_add_action(SKILL, [_mouse_button(MOUSE_BUTTON_RIGHT), _joy_button(JOY_BUTTON_Y)])
	_add_action(DASH, [_key(KEY_SPACE), _joy_button(JOY_BUTTON_B)])
	_add_action(SWAP_1, [_key(KEY_1)])
	_add_action(SWAP_2, [_key(KEY_2)])
	_add_action(SWAP_3, [_key(KEY_3)])
	_add_action(SWAP_NEXT, [_joy_button(JOY_BUTTON_DPAD_UP)])
	_add_action(SWAP_PREV, [_joy_button(JOY_BUTTON_DPAD_DOWN)])


static func move_intent() -> Vector2:
	return Input.get_vector(MOVE_LEFT, MOVE_RIGHT, MOVE_UP, MOVE_DOWN)


static func _add_action(action: StringName, events: Array[InputEvent]) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if InputMap.action_get_events(action).is_empty():
		for event: InputEvent in events:
			InputMap.action_add_event(action, event)


static func _key(physical_keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = physical_keycode
	return event


static func _mouse_button(button_index: MouseButton) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	return event


static func _joy_button(button_index: JoyButton) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	return event


static func _joy_axis(axis: JoyAxis, axis_value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = axis_value
	return event
