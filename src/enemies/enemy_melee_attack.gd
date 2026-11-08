class_name EnemyMeleeAttack
extends RefCounted
## Per-enemy melee executor. Owns mutable attack data and its reused damage result;
## shared EnemyDefinition resources are read only.

var attack := AttackDefinition.new()
var last_result := DamageResult.new()


func configure(definition: EnemyDefinition) -> void:
	attack.id = "melee"
	attack.damage_type = CombatTypes.DamageType.PHYSICAL
	attack.base_damage = definition.attack_damage
	attack.poise_damage = definition.poise_damage
	attack.knockback_distance = definition.attack_knockback
	attack.tags = CombatTypes.AttackTag.MELEE
	attack.status_applications = []


## Rechecks target combat state, range and terrain immediately before dealing damage.
## A pre-deal no-op leaves last_result unchanged, including after a previous hit.
func strike(damage_system: DamageSystem, combat: CombatantState,
		perception: EnemyPerception, definition: EnemyDefinition, map: RoomMap,
		parent: Node, position: Vector2, pixels_per_meter: float, level: int,
		expected_actor_id: int = -1) -> void:
	if damage_system == null or combat == null or not combat.can_act():
		return
	var target := perception.target_combat_state()
	if target == null or (expected_actor_id != -1 and target.actor_id != expected_actor_id):
		return
	if perception.distance_m(parent, position, pixels_per_meter) > definition.attack_range:
		return
	if perception.target_level(map, parent, pixels_per_meter, level) != level:
		return
	damage_system.deal(attack, combat, target, last_result, 1.0,
			(perception.target_local(parent) - position).normalized())
