class_name HeroInputNode
extends Node
## Samples InputMap once per physics frame and emits a self-contained HeroInputFrame.
## The simulation owner applies the frame and advances PartyController separately.

signal frame_ready(frame: HeroInputFrame)

var _next_sequence := 1


func _physics_process(_delta: float) -> void:
	var frame := HeroInputFrame.new()
	frame.sequence = _next_sequence
	_next_sequence += 1
	frame.move = HeroInput.move_intent()
	if Input.is_action_just_pressed(HeroInput.ATTACK):
		frame.press(HeroInputFrame.Action.ATTACK)
	if Input.is_action_just_pressed(HeroInput.SKILL):
		frame.press(HeroInputFrame.Action.SKILL)
	if Input.is_action_just_pressed(HeroInput.DASH):
		frame.press(HeroInputFrame.Action.DASH)
	if Input.is_action_just_pressed(HeroInput.SWAP_1):
		frame.press(HeroInputFrame.Action.SWAP_1)
	if Input.is_action_just_pressed(HeroInput.SWAP_2):
		frame.press(HeroInputFrame.Action.SWAP_2)
	if Input.is_action_just_pressed(HeroInput.SWAP_3):
		frame.press(HeroInputFrame.Action.SWAP_3)
	if Input.is_action_just_pressed(HeroInput.SWAP_NEXT):
		frame.press(HeroInputFrame.Action.SWAP_NEXT)
	if Input.is_action_just_pressed(HeroInput.SWAP_PREV):
		frame.press(HeroInputFrame.Action.SWAP_PREV)
	frame_ready.emit(frame)
