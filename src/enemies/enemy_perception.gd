class_name EnemyPerception
extends RefCounted
## Per-enemy candidate list and selected target. Visibility remains scene visibility;
## coordinate conversion and combat-state lookup preserve the baseline target policy.

var target: Node2D
var _heroes: Array[Node2D] = []


func set_targets(heroes: Array[Node2D]) -> void:
	_heroes = heroes.duplicate()
	target = null


## Nearest visible living hero wins; equal distances are resolved by actor id.
## Position is in the enemy parent's local pixels; distances are measured in meters.
func select_target(parent: Node, position: Vector2, pixels_per_meter: float) -> void:
	var best: Node2D = null
	var best_distance := INF
	var best_actor_id := 0
	for candidate: Node2D in _heroes:
		if not is_instance_valid(candidate) or not candidate.is_visible_in_tree():
			continue
		var candidate_state := _combat_state_of(candidate)
		if candidate_state != null and not candidate_state.alive:
			continue
		var local: Vector2 = parent.to_local(candidate.global_position) if parent != null else candidate.position
		var distance := position.distance_to(local) / pixels_per_meter
		var actor_id := candidate_state.actor_id if candidate_state != null else 0
		if best == null or distance < best_distance \
				or (is_equal_approx(distance, best_distance) and actor_id < best_actor_id):
			best = candidate
			best_distance = distance
			best_actor_id = actor_id
	target = best


## Target position in the enemy parent's local pixels, or zero without a target.
func target_local(parent: Node) -> Vector2:
	if target == null or not is_instance_valid(target):
		return Vector2.ZERO
	if parent == null:
		return target.position
	return parent.to_local(target.global_position)


func distance_m(parent: Node, position: Vector2, pixels_per_meter: float) -> float:
	if target == null or not is_instance_valid(target):
		return INF
	return position.distance_to(target_local(parent)) / pixels_per_meter


## Outside the map or over a pit, keep the enemy's level for melee validation.
func target_level(map: RoomMap, parent: Node, pixels_per_meter: float,
		fallback_level: int) -> int:
	if map == null:
		return fallback_level
	var local := target_local(parent)
	var hero_cell := Vector2i(
			floori(local.x / (WorldUnits.CELL_SIZE * pixels_per_meter)),
			floori(local.y / (WorldUnits.CELL_SIZE * pixels_per_meter)))
	if not map.is_ground(hero_cell):
		return fallback_level
	return map.level_at(hero_cell)


func target_combat_state() -> CombatantState:
	return _combat_state_of(target)


func _combat_state_of(hero: Node2D) -> CombatantState:
	if hero == null or not is_instance_valid(hero):
		return null
	return hero.get("combatant_state") as CombatantState
