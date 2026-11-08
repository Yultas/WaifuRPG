class_name Hitbox2D
extends Area2D
## Active area of an attack: melee swing, projectile or explosion. Detects Hurtbox2D
## overlaps, filters factions, applies repeat-hit rules through HitRegistry and hands every
## accepted hit to DamageSystem.deal, passing the hitbox -> hurtbox direction as the
## knockback direction. Delivery happens on physics ticks (the combat ticks),
## never on render frames. Does not calculate or apply damage itself beyond that call.
##
## The host drives combat by enabling this node for the active frames of an attack with a
## unique nonzero attack_instance_id, then calling end_attack() or freeing the node.

var attack: AttackDefinition
var source: CombatantState
## Unique per attack instance; 0 disables registry tracking (host-managed direct hits).
var attack_instance_id := 0
## Multiplier on the attack's base damage for this instance.
var damage_scale := 1.0
var damage_system: DamageSystem
var registry: HitRegistry
## Current combat tick. The host may overwrite it to align with authoritative simulation.
var combat_tick := 0

var _result := DamageResult.new()
var _last_simulation_tick := -1


func _init() -> void:
	collision_layer = Hurtbox2D.HITBOX_BIT
	collision_mask = Hurtbox2D.LAYER_BIT


func _exit_tree() -> void:
	_cleanup_attack()


## Re-evaluates current overlaps once per authoritative tick. HitRegistry decides which
## ones become hits, so i-frames, death and repeat limits do not rely on area signals.
func tick() -> void:
	combat_tick += 1
	if not monitoring or attack == null or damage_system == null:
		return
	var victims: Array[Hurtbox2D] = []
	for area: Area2D in get_overlapping_areas():
		if area is Hurtbox2D:
			victims.append(area)
	_sort_victims(victims)
	for hurtbox: Hurtbox2D in victims:
		_try_hit(hurtbox)


## Current-geometry delivery for the phased room, with one clock step per simulation tick.
func tick_current(shape: Shape2D, transform: Transform2D,
		space_state: PhysicsDirectSpaceState2D, simulation_tick: int) -> int:
	if _last_simulation_tick == simulation_tick:
		return 0
	_last_simulation_tick = simulation_tick
	combat_tick += 1
	return deal_aoe(shape, transform, space_state)


## Stops the attack: removes its registry entries and disables further delivery.
func end_attack() -> void:
	_cleanup_attack()
	monitoring = false

## Instant AoE: delivers the attack to every hurtbox intersecting `shape` at `transform`.
## Must be called during the room physics tick, when the direct space state is accessible.
## Returns the number of hits actually delivered.
func deal_aoe(shape: Shape2D, transform: Transform2D,
		space_state: PhysicsDirectSpaceState2D) -> int:
	if not monitoring or attack == null or damage_system == null:
		return 0
	var delivered := 0
	var victims := query_hurtboxes(space_state, shape, transform)
	_sort_victims(victims)
	for hurtbox: Hurtbox2D in victims:
		if _try_hit(hurtbox):
			delivered += 1
	return delivered


## Shape query against hurtboxes only; usable for instant AoE and trap checks.
static func query_hurtboxes(space_state: PhysicsDirectSpaceState2D, shape: Shape2D,
		transform: Transform2D, max_results := 64) -> Array[Hurtbox2D]:
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = transform
	params.collision_mask = Hurtbox2D.LAYER_BIT
	params.collide_with_areas = true
	params.collide_with_bodies = false
	var hurtboxes: Array[Hurtbox2D] = []
	for hit: Dictionary in space_state.intersect_shape(params, max_results):
		var collider: Object = hit.get("collider")
		if collider is Hurtbox2D:
			hurtboxes.append(collider)
	return hurtboxes


func _try_hit(hurtbox: Hurtbox2D) -> bool:
	if not monitoring or damage_system == null or not is_instance_valid(hurtbox):
		return false
	if source != null and not source.can_act():
		return false
	var target := hurtbox.combatant
	if attack == null or target == null:
		return false
	if not target.alive or target.invulnerable_ticks > 0:
		return false
	if source != null and (source.actor_id == target.actor_id \
			or source.faction == target.faction):
		return false
	if attack_instance_id != 0:
		var cooldown_ticks := roundi(attack.hit_cooldown * damage_system.ticks_per_second)
		if not registry.register_hit(attack_instance_id, target.actor_id, combat_tick,
				cooldown_ticks, attack.max_hits_per_target):
			return false
	damage_system.deal(attack, source, target, _result, damage_scale,
			hurtbox.global_position - global_position)
	if _result.prevented:
		# The hit did not land (target died or turned invulnerable before damage
		# resolved): hand the hit budget back so a later tick can still deliver it.
		if attack_instance_id != 0:
			registry.rollback_hit(attack_instance_id, target.actor_id)
		return false
	return true


func _sort_victims(victims: Array[Hurtbox2D]) -> void:
	victims.sort_custom(func(a: Hurtbox2D, b: Hurtbox2D) -> bool:
		return a.actor_id() < b.actor_id())


func _cleanup_attack() -> void:
	if registry != null and attack_instance_id != 0:
		registry.clear_attack(attack_instance_id)
