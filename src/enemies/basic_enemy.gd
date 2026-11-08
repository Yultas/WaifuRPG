class_name BasicEnemy
extends CharacterBody2D
## First baseline melee enemy: idle -> chase (inside detection_range) -> telegraph
## (immobile for telegraph_duration) -> strike -> cooldown. Pathing goes through its own
## NavigationAgent2D; walls are avoided with move_and_slide against RoomCollision layers.
## Gameplay values are in meters and seconds (see EnemyDefinition); pixels come from
## pixels_per_meter, the parent node's local space (renderer.actors).
##
## Combat integration: with an injected DamageSystem the enemy owns a CombatantState
## (ENEMY faction, configured from EnemyDefinition, which is a CombatantDefinition) and
## deals damage through DamageSystem.deal instead of calling the hero directly. Without
## a DamageSystem it keeps the old harmless behavior (strike is a no-op).
## The strike re-validates after the telegraph: target combat state still present, hero
## inside attack_range, hero on the enemy's terrain level. DamageSystem itself rejects
## dead or invulnerable (i-frames) targets. Stun, freeze and hitstop freeze the whole
## state machine via CombatantState.can_act(); knockback is the exception — it is forced
## displacement (combat.knockback_offset) that keeps sliding the enemy through
## move_and_slide until knockback_ticks runs out, even while the machine is frozen, so a
## staggered enemy is still pushed.
##
## All combat timers count fixed 60 Hz ticks, never delta seconds, so attack cadence does
## not depend on render FPS. The owning room calls tick() for state and movement;
## _process only presents the state (body color, telegraph ring), never changes it.

const State = EnemyBrain.State

## Combat simulation rate: one physics frame at 60 Hz is one combat tick.
const TICKS_PER_SECOND := 60

@export var definition: EnemyDefinition

var map: RoomMap
var pixels_per_meter := WorldUnits.PIXELS_PER_METER
var level := 0
## Read-only for outside observers (tests); changed only by the state machine.
var state: EnemyBrain.State:
	get:
		return _brain.state
## Injected by the owning room/world before enter_room. The single entry point for
## outgoing damage and the registry this enemy's CombatantState lives in.
var damage_system: DamageSystem
## Status balance for this enemy's CombatantState; defaults match docs/gdd/03_combat.md.
var status_config: StatusConfig = StatusConfig.new()
## Read-only for outside observers: this enemy's runtime combat state.
var combat: CombatantState
## Reused result of the last DamageSystem.deal; read-only for outside observers (tests).
var last_result: DamageResult:
	get:
		return _melee.last_result

## Measured displacement after wall clamping, in meters per second.
var actual_velocity_mps := Vector2.ZERO
var _phase_context: EnemyRoomContext
var _phase_frame: EnemyRoomSnapshot
var _phase_tick := -1
var _phase_epoch := -1
var _participates := false
var _decided := false
var _planned := false
var _moved := false
var _executed := false
var _intent: EnemyBrain.Intent = EnemyBrain.Intent.NONE
var _knockback := Vector2.ZERO
var _goal_m := Vector2.ZERO
var _target_actor_id := -1
var _strike_pending := false

var _brain := EnemyBrain.new()
var _perception := EnemyPerception.new()
var _navigation := EnemyNavigation.new()
var _melee := EnemyMeleeAttack.new()

## Compatibility projections; runtime state belongs to the corresponding adapter.
var _hero: Node2D:
	get:
		return _perception.target
var _attack: AttackDefinition:
	get:
		return _melee.attack
var _agent: NavigationAgent2D
var _shape: CollisionShape2D
var _body: Polygon2D
var _ring: Line2D


func _init() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	collision_layer = 0
	_shape = CollisionShape2D.new()
	_shape.shape = CircleShape2D.new()
	add_child(_shape)
	_agent = NavigationAgent2D.new()
	_agent.avoidance_enabled = false
	add_child(_agent)
	_body = Polygon2D.new()
	add_child(_body)
	_ring = Line2D.new()
	_ring.closed = true
	add_child(_ring)
	_reshape()


## Places the enemy at the center of a cell and supplies all possible hero targets.
## The run owner supplies the stable actor id before combat registration.
func enter_room(room_map: RoomMap, local_pixels_per_meter: float, cell: Vector2i,
		heroes: Array[Node2D], actor_id: int) -> void:
	map = room_map
	pixels_per_meter = local_pixels_per_meter
	set_targets(heroes)
	(_shape.shape as CircleShape2D).radius = _def().radius * pixels_per_meter
	_reshape()
	position = (Vector2(cell) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE * pixels_per_meter
	velocity = Vector2.ZERO
	_brain.reset()
	_configure_combat(actor_id)
	_update_level()


func set_targets(heroes: Array[Node2D]) -> void:
	_perception.set_targets(heroes)


## Position in meters, room-local.
func meters() -> Vector2:
	return position / pixels_per_meter


## Grid cell under the enemy's feet (may be outside the room near a door).
func cell() -> Vector2i:
	var p := position / (WorldUnits.CELL_SIZE * pixels_per_meter)
	return Vector2i(floori(p.x), floori(p.y))


func _exit_tree() -> void:
	if damage_system != null and combat != null:
		damage_system.unregister_combatant(combat.actor_id)


func _def() -> EnemyDefinition:
	if definition == null:
		definition = EnemyDefinition.new()
	return definition


## Owns the CombatantState built from this enemy's EnemyDefinition (a
## CombatantDefinition) and registers it with the injected DamageSystem. Without a
## DamageSystem there is no combat state and strikes stay no-ops.
func _configure_combat(actor_id: int) -> void:
	if damage_system == null:
		return
	if combat == null:
		combat = CombatantState.new()
	var def := _def()
	combat.configure(def, actor_id,
			CombatTypes.Faction.ENEMY, status_config, TICKS_PER_SECOND)
	damage_system.register_combatant(combat)
	_melee.configure(def)


## Compatibility facade for standalone callers. Preview uses the guarded phases below.
func tick() -> void:
	_prepare_combat()
	_perception.select_target(get_parent(), position, pixels_per_meter)
	_choose_intent(_perception.distance_m(get_parent(), position, pixels_per_meter))
	_goal_m = _perception.target_local(get_parent()) / pixels_per_meter
	_plan_velocity()
	_apply_movement()
	_consume_strike()


## Caches forced displacement BEFORE ticking combat; newly dead bodies never move.
func prepare_tick(context: EnemyRoomContext) -> void:
	if _phase_context == context and _phase_tick == context.tick and _phase_epoch == context.epoch:
		return
	_phase_context = context
	_phase_tick = context.tick
	_phase_epoch = context.epoch
	_phase_frame = null
	_participates = false
	_decided = false
	_planned = false
	_moved = false
	_executed = false
	_strike_pending = false
	_prepare_combat()


## Every enemy observes this same value-only frame before any body moves.
func decide_tick(context: EnemyRoomContext) -> void:
	if not _phase_matches(context) or _decided or not context.is_current(context.snapshot):
		return
	_decided = true
	_phase_frame = context.snapshot
	var own := _phase_frame.actor(combat.actor_id) if combat != null else null
	if own == null or context.resolve_actor(combat.actor_id, _phase_frame) != self:
		return
	_participates = true
	_perception.select_snapshot(_phase_frame, own.position_m)
	_target_actor_id = _perception.selected_actor_id
	_goal_m = _perception.captured_position_m
	_perception.target = context.resolve_actor(_target_actor_id, _phase_frame)
	_choose_intent(_perception.captured_distance_m)


func plan_tick(context: EnemyRoomContext) -> void:
	if not _frame_matches(context) or not _participates or not _decided or _planned:
		return
	_planned = true
	_plan_velocity()


func move_tick(context: EnemyRoomContext) -> void:
	if not _frame_matches(context) or not _planned or _moved:
		return
	_moved = true
	_apply_movement()


## Consumes the attempt before calling damage handlers (which may reenter).
## Delivery uses current geometry and the current-tick selected actor, not a new selection.
func execute_tick(context: EnemyRoomContext) -> void:
	if not _frame_matches(context) or not _moved or _executed:
		return
	_executed = true
	_perception.target = context.resolve_actor(_target_actor_id, _phase_frame)
	_consume_strike(_target_actor_id)


func _phase_matches(context: EnemyRoomContext) -> bool:
	return _phase_context == context and _phase_tick == context.tick and _phase_epoch == context.epoch


func _frame_matches(context: EnemyRoomContext) -> bool:
	return _phase_matches(context) and context.is_current(_phase_frame)


func _prepare_combat() -> void:
	_intent = EnemyBrain.Intent.NONE
	_strike_pending = false
	_knockback = combat.knockback_offset() if combat != null and combat.alive else Vector2.ZERO
	if combat != null:
		combat.tick(damage_system)
		if not combat.alive:
			_knockback = Vector2.ZERO
			velocity = Vector2.ZERO
			actual_velocity_mps = Vector2.ZERO


func _choose_intent(distance_m: float) -> void:
	var def := _def()
	_intent = _brain.tick(distance_m, def.detection_range, def.attack_range,
			roundi(def.telegraph_duration * TICKS_PER_SECOND), combat == null or combat.can_act())
	_strike_pending = _intent == EnemyBrain.Intent.STRIKE


func _plan_velocity() -> void:
	velocity = Vector2.ZERO
	if combat != null and not combat.alive:
		return
	if _intent == EnemyBrain.Intent.CHASE:
		velocity = _navigation.chase_velocity_to(_agent, _goal_m * pixels_per_meter,
				get_parent(), position, _def().speed, pixels_per_meter)
	velocity += _knockback * float(TICKS_PER_SECOND) * pixels_per_meter


func _apply_movement() -> void:
	var before := position
	if combat == null or combat.alive:
		move_and_slide()
	else:
		velocity = Vector2.ZERO
	actual_velocity_mps = (position - before) / pixels_per_meter * float(TICKS_PER_SECOND)
	_update_level()
	# Child Area2D transforms must reach the physics server before this tick's queries.
	for child: Node in get_children():
		if child is Hurtbox2D:
			child.force_update_transform()


func _consume_strike(expected_actor_id: int = -1) -> void:
	if not _strike_pending:
		return
	_strike_pending = false
	_melee.strike(damage_system, combat, _perception, _def(), map, get_parent(),
			position, pixels_per_meter, level, expected_actor_id)
	_brain.finish_strike(roundi(_def().attack_cooldown * TICKS_PER_SECOND))


func _update_level() -> void:
	var c := cell()
	if map != null and map.is_ground(c):
		level = map.level_at(c)
	collision_mask = RoomCollision.layer_bit(level)


func _process(_delta: float) -> void:
	var def := _def()
	if state == State.TELEGRAPH:
		var progress := 1.0 - float(_brain.telegraph_ticks) / maxf(float(_brain.telegraph_total), 1.0)
		_body.modulate = Color(1.0, 0.45 + 0.45 * progress, 0.4)
		_ring.modulate = Color(1.0, 0.25, 0.2, 0.35 + 0.6 * progress)
		_ring.scale = Vector2.ONE * (1.0 + 0.25 * (1.0 - progress))
		_ring.visible = true
	else:
		_body.modulate = Color(0.85, 0.3, 0.38)
		_ring.visible = false


## (Re)builds the placeholder body and telegraph ring from pixels_per_meter: a dark disc
## for the body, a thin ring around it that lights up while telegraphing.
func _reshape() -> void:
	var radius_px := maxf(_def().radius, 0.2) * pixels_per_meter
	var body_points := PackedVector2Array()
	var ring_points := PackedVector2Array()
	for i in 16:
		var angle := TAU * i / 16.0
		body_points.append(Vector2(cos(angle), sin(angle)) * radius_px)
		ring_points.append(Vector2(cos(angle), sin(angle)) * radius_px * 1.8)
	_body.polygon = body_points
	_ring.points = ring_points
	_ring.width = maxf(0.06 * pixels_per_meter, 1.0)
	_body.modulate = Color(0.85, 0.3, 0.38)
	_ring.modulate = Color(1.0, 0.25, 0.2)
	_ring.visible = false
