class_name HeroInputFrame
extends RefCounted

## One fixed-tick command packet for a party. Contains intents only, never positions,
## damage or references to scene nodes, so the same data can come from InputMap or network.

enum Action {
	ATTACK = 1 << 0,
	SKILL = 1 << 1,
	DASH = 1 << 2,
	SWAP_1 = 1 << 3,
	SWAP_2 = 1 << 4,
	SWAP_3 = 1 << 5,
	SWAP_NEXT = 1 << 6,
	SWAP_PREV = 1 << 7,
}

var sequence := 0
var move := Vector2.ZERO
var pressed := 0


func press(action: Action) -> void:
	pressed |= action


func is_pressed(action: Action) -> bool:
	return (pressed & action) != 0
