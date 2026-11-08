class_name CombatHeroView
extends CharacterBody2D
## Scene adapter binding one PartyController hero slot to the room. It mirrors the
## HeroActionController position (meters, authoritative combat sim) into the pixel world
## with wall clamping through move_and_slide (RoomCollision layers), carries the hero's
## Hurtbox2D so enemy strikes and hero hitboxes resolve through the shared DamageSystem,
## and draws the sprite. Only the active view is visible; pocket heroes stay hidden in the
## room but keep ticking through PartyController, so their cooldowns and statuses run.
## Gameplay values stay in meters; pixels come from pixels_per_meter, the parent node's
## local space (renderer.actors).
##
## Pocket-dash position contract (HeroActionController.tick): a dash survives a swap —
## while the benched hero's action is DASHING, the pocket tick keeps displacing
## controller.position along dash_direction (no dash distance is lost), then the position
## freezes. The hidden pocket view intentionally does not sync: it must not feed its
## stale position back into the advancing controller, and on re-activation the
## controller's displaced position is authoritative, so the view catches up in one tick.

const SHEET := preload("res://tiles/Sprout Lands - Sprites - Basic pack/Characters/Basic Charakter Spritesheet.png")
## The sheet art is drawn at this scale.
const SHEET_PIXELS_PER_METER := 16.0
const FRAME_FPS := 8.0
## Slightly larger than the movement circle, so melee connects at attack_range.
const HURTBOX_RADIUS := 0.35
enum Facing { DOWN, UP, LEFT, RIGHT }

## Position/Combatant stand-in handed to BasicEnemy: the enemy AI watches the proxy,
## which the active view keeps glued to itself, so strikes and pathing track the hero
## currently in play (including right after a swap).
class HeroProxy:
	extends Node2D
	var combatant_state: CombatantState


var hero_state: HeroCombatState
var controller: HeroActionController
var proxy: HeroProxy
var map: RoomMap
var pixels_per_meter := WorldUnits.PIXELS_PER_METER
var level := 0
## Visible height in meters, used to fade props that hide the hero.
var height := 1.0
## The pocket hero is hidden and does not sync with the world.
var active := false

var _sprite: Sprite2D
var _shape: CollisionShape2D
var _hurt_shape: CollisionShape2D
var _hurtbox: Hurtbox2D
var _facing := Facing.DOWN
var _anim_time := 0.0
var _hp_last := -1.0
var _flash_ticks := 0


func _init() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	collision_layer = 0
	# After HeroInputNode (-20) and the room simulation (0), so positions are current.
	process_physics_priority = 1
	_shape = CollisionShape2D.new()
	_shape.shape = CircleShape2D.new()
	add_child(_shape)
	_hurtbox = Hurtbox2D.new()
	_hurt_shape = CollisionShape2D.new()
	_hurt_shape.shape = CircleShape2D.new()
	_hurtbox.add_child(_hurt_shape)
	add_child(_hurtbox)
	_sprite = Sprite2D.new()
	_sprite.texture = SHEET
	_sprite.hframes = 4
	_sprite.vframes = 4
	# Feet are 8 px below the frame center.
	_sprite.offset = Vector2(0, -8)
	add_child(_sprite)


func bind(state_value: HeroCombatState, controller_value: HeroActionController) -> void:
	hero_state = state_value
	controller = controller_value
	_hurtbox.combatant = hero_state


## Places the hero at the center of a cell of the given room and snaps the view there.
func enter_room(room_map: RoomMap, local_pixels_per_meter: float, cell: Vector2i) -> void:
	map = room_map
	pixels_per_meter = local_pixels_per_meter
	(_shape.shape as CircleShape2D).radius = hero_state.hero_definition.radius * pixels_per_meter
	(_hurt_shape.shape as CircleShape2D).radius = HURTBOX_RADIUS * pixels_per_meter
	_sprite.scale = Vector2.ONE * pixels_per_meter / SHEET_PIXELS_PER_METER
	var meters := (Vector2(cell) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE
	controller.position = meters
	position = meters * pixels_per_meter
	velocity = Vector2.ZERO
	_hp_last = hero_state.hp
	_update_level()


## Grid cell under the hero's feet (may be outside the room while leaving through a door).
func cell() -> Vector2i:
	var p := position / (WorldUnits.CELL_SIZE * pixels_per_meter)
	return Vector2i(floori(p.x), floori(p.y))


## Position in meters, room-local.
func meters() -> Vector2:
	return position / pixels_per_meter


## The property BasicEnemy pulls off the watched node.
func combatant_state() -> CombatantState:
	return hero_state


func _physics_process(_delta: float) -> void:
	if hero_state == null:
		return
	if active and controller != null and hero_state.alive:
		# While the hero sits in the pocket the view stays stale on purpose (the
		# pocket dash displaces the controller on its own — see the class doc), so
		# the sync below must run only now, catching the view up in one tick.
		var target := controller.position * pixels_per_meter
		velocity = (target - position) * float(Engine.physics_ticks_per_second)
		move_and_slide()
		# Wall clamping feeds back into the sim so the next tick starts from the
		# real position (dashes stop at walls too).
		controller.position = position / pixels_per_meter
		if proxy != null:
			proxy.position = position
			proxy.combatant_state = hero_state
		_update_level()
	_present(_delta)


func _update_level() -> void:
	var c := cell()
	if map != null and map.is_ground(c):
		level = map.level_at(c)
	collision_mask = RoomCollision.layer_bit(level)


func _present(delta: float) -> void:
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
	var dir := controller.facing if controller != null else Vector2.DOWN
	if dir == Vector2.ZERO:
		dir = Vector2.DOWN
	if dir.length_squared() > 0.0:
		if absf(dir.x) > absf(dir.y):
			_facing = Facing.RIGHT if dir.x > 0 else Facing.LEFT
		else:
			_facing = Facing.DOWN if dir.y > 0 else Facing.UP
	if hero_state.action == HeroCombatState.Action.IDLE and controller != null \
			and controller.move_intent == Vector2.ZERO:
		_anim_time = 0.0
	else:
		_anim_time += delta
	_sprite.frame = _facing * 4 + int(_anim_time * FRAME_FPS) % 4
