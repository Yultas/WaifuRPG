class_name RemoteHeroView
extends Node2D

## Presentation-only hero replica. Snapshots move this view directly; it has no
## controller, gameplay collision or hurtbox and never writes to authoritative state.

const FRAME_FPS := 8.0

enum Facing { DOWN, UP, LEFT, RIGHT }

var hero_state: HeroCombatState
var pixels_per_meter := WorldUnits.PIXELS_PER_METER
var active := true

var _sprite: Sprite2D
var _facing := Vector2.DOWN
var _facing_index := Facing.DOWN
var _anim_time := 0.0
var _hp_last := -1.0
var _flash_ticks := 0


func _init() -> void:
	_sprite = Sprite2D.new()
	_sprite.texture = CombatHeroView.SHEET
	_sprite.hframes = 4
	_sprite.vframes = 4
	_sprite.offset = Vector2(0, -8)
	add_child(_sprite)


func bind(state: HeroCombatState) -> void:
	hero_state = state
	_hp_last = state.hp
	_sprite.scale = Vector2.ONE * pixels_per_meter / CombatHeroView.SHEET_PIXELS_PER_METER


func apply_snapshot(position_m: Vector2, facing: Vector2, is_active: bool) -> void:
	position = position_m * pixels_per_meter
	if not facing.is_zero_approx():
		_facing = facing.normalized()
	active = is_active
	visible = active


func _process(delta: float) -> void:
	if hero_state == null:
		return
	visible = active
	if not hero_state.alive:
		_sprite.modulate = Color(0.4, 0.4, 0.45)
		_sprite.frame = Facing.DOWN * 4
		return
	if _hp_last >= 0.0 and hero_state.hp < _hp_last:
		_flash_ticks = 4
	_hp_last = hero_state.hp
	if _flash_ticks > 0:
		_flash_ticks -= 1
		_sprite.modulate = Color(1.0, 0.5, 0.5)
	else:
		_sprite.modulate = Color.WHITE
	if absf(_facing.x) > absf(_facing.y):
		_facing_index = Facing.RIGHT if _facing.x > 0.0 else Facing.LEFT
	elif not _facing.is_zero_approx():
		_facing_index = Facing.DOWN if _facing.y > 0.0 else Facing.UP
	if hero_state.action == HeroCombatState.Action.IDLE:
		_anim_time = 0.0
	else:
		_anim_time += delta
	_sprite.frame = _facing_index * 4 + int(_anim_time * FRAME_FPS) % 4
