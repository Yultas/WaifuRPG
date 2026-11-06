class_name TestHero
extends CharacterBody2D
## Debug character for walking rooms (WASD). It collides only with the walls of the level
## it stands on (see RoomCollision). Its level follows the cell under its feet, and the
## only open edges between levels are stairs, so it changes level only there.
## Gameplay values are in meters and seconds; pixels come from pixels_per_meter, the
## parent's local scale.

const SHEET := preload("res://tiles/Sprout Lands - Sprites - Basic pack/Characters/Basic Charakter Spritesheet.png")
## The sheet art is drawn at this scale.
const SHEET_PIXELS_PER_METER := 16.0
const FRAME_FPS := 8.0
enum Facing { DOWN, UP, LEFT, RIGHT }

## Meters per second.
@export var speed := 5.0
## Collision radius in meters.
@export var radius := 0.3
## Visible height in meters, used to fade props that hide the hero.
@export var height := 1.0

var map: RoomMap
var pixels_per_meter := WorldUnits.PIXELS_PER_METER
var level := 0
## Movement direction for scripted control (tests). Used when keyboard is off.
var steer := Vector2.ZERO
var use_keyboard := true

var _sprite: Sprite2D
var _shape: CollisionShape2D
var _facing := Facing.DOWN
var _anim_time := 0.0


func _init() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	collision_layer = 0
	_shape = CollisionShape2D.new()
	_shape.shape = CircleShape2D.new()
	add_child(_shape)
	_sprite = Sprite2D.new()
	_sprite.texture = SHEET
	_sprite.hframes = 4
	_sprite.vframes = 4
	# Feet are 8 px below the frame center.
	_sprite.offset = Vector2(0, -8)
	add_child(_sprite)


## Places the hero at the center of a cell of the given room.
func enter_room(room_map: RoomMap, local_pixels_per_meter: float, cell: Vector2i) -> void:
	map = room_map
	pixels_per_meter = local_pixels_per_meter
	(_shape.shape as CircleShape2D).radius = radius * pixels_per_meter
	_sprite.scale = Vector2.ONE * pixels_per_meter / SHEET_PIXELS_PER_METER
	position = (Vector2(cell) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE * pixels_per_meter
	velocity = Vector2.ZERO
	_update_level()


## Grid cell under the hero's feet (may be outside the room while leaving through a door).
func cell() -> Vector2i:
	var p := position / (WorldUnits.CELL_SIZE * pixels_per_meter)
	return Vector2i(floori(p.x), floori(p.y))


## Position in meters, room-local.
func meters() -> Vector2:
	return position / pixels_per_meter


func _physics_process(delta: float) -> void:
	var dir := steer
	if use_keyboard:
		dir = Vector2(
			int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A)),
			int(Input.is_physical_key_pressed(KEY_S)) - int(Input.is_physical_key_pressed(KEY_W)))
	velocity = dir.normalized() * speed * pixels_per_meter
	move_and_slide()
	_update_level()
	_animate(dir, delta)


func _update_level() -> void:
	var c := cell()
	if map != null and map.is_ground(c):
		level = map.level_at(c)
	collision_mask = RoomCollision.layer_bit(level)


func _animate(dir: Vector2, delta: float) -> void:
	if dir == Vector2.ZERO:
		_anim_time = 0.0
	else:
		_anim_time += delta
		if absf(dir.x) > absf(dir.y):
			_facing = Facing.RIGHT if dir.x > 0 else Facing.LEFT
		else:
			_facing = Facing.DOWN if dir.y > 0 else Facing.UP
	_sprite.frame = _facing * 4 + int(_anim_time * FRAME_FPS) % 4
