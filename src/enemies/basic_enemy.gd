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


## Advances the enemy by one fixed tick. The room simulation owns the call order.
func tick() -> void:
	_perception.select_target(get_parent(), position, pixels_per_meter)
	# Knockback is forced displacement, not state machine motion: it keeps sliding
	# the enemy even while stun/freeze/hitstop freeze the machine, so a staggered
	# enemy is still visibly pushed. Read before combat.tick() decrements
	# knockback_ticks; move_and_slide keeps the slide out of the walls.
	var knockback := Vector2.ZERO
	if combat != null and combat.alive:
		knockback = combat.knockback_offset()
	if combat != null:
		combat.tick(damage_system)
		if not combat.can_act():
			velocity = knockback * float(TICKS_PER_SECOND) * pixels_per_meter
			if not velocity.is_zero_approx():
				move_and_slide()
			return
	var def := _def()
	var intent := _brain.tick(_perception.distance_m(get_parent(), position, pixels_per_meter),
			def.detection_range, def.attack_range, roundi(def.telegraph_duration * TICKS_PER_SECOND))
	velocity = Vector2.ZERO
	match intent:
		EnemyBrain.Intent.CHASE:
			velocity = _navigation.chase_velocity(_agent, _perception.target, get_parent(),
					position, def.speed, pixels_per_meter)
		EnemyBrain.Intent.STRIKE:
			_melee.strike(damage_system, combat, _perception, def, map, get_parent(),
					position, pixels_per_meter, level)
			_brain.finish_strike(roundi(_def().attack_cooldown * TICKS_PER_SECOND))
	if not knockback.is_zero_approx():
		velocity += knockback * float(TICKS_PER_SECOND) * pixels_per_meter
	move_and_slide()
	_update_level()


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
