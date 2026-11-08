class_name ModifierSet
extends RefCounted
## Runtime modifiers and a lazily rebuilt stat snapshot for one combatant.


var instances: Array[ModifierInstance] = []
var conditional: Array[ModifierInstance] = []
var stats := CombatStats.new()
var stats_dirty := true
var rebuild_count := 0
var ticks_per_second := 60
var _sequence := 0


func add(definition: ModifierDefinition, source_id: int = -1) -> ModifierInstance:
	for instance: ModifierInstance in instances:
		if instance.definition.id != definition.id:
			continue
		var stacks_changed := false
		if definition.adds_stack_on_reapply:
			var new_stacks: int = mini(instance.stacks + 1, maxi(1, definition.max_stacks))
			stacks_changed = new_stacks != instance.stacks
			instance.stacks = new_stacks
		if definition.refreshes_duration:
			instance.remaining_ticks = roundi(definition.duration * ticks_per_second)
		instance.source_id = source_id
		if stacks_changed and _aggregated_in_stats(definition):
			stats_dirty = true
		return instance
	var instance := ModifierInstance.new(definition, ticks_per_second)
	instance.source_id = source_id
	instance.sequence = _sequence
	_sequence += 1
	var index := _insertion_index(definition.priority)
	var conditional_rank := 0
	for existing: ModifierInstance in instances:
		if existing.definition.priority > definition.priority:
			break
		if _appears_in_conditional(existing.definition):
			conditional_rank += 1
	instances.insert(index, instance)
	if _appears_in_conditional(definition):
		conditional.insert(mini(conditional_rank, conditional.size()), instance)
	if _aggregated_in_stats(definition):
		stats_dirty = true
	return instance


## Releases every instance reference held by this set. Required when a
## handler callback captures the set itself: otherwise the capture cycle
## (set -> definition -> handler -> lambda -> set) keeps everything alive.
func clear() -> void:
	instances.clear()
	conditional.clear()
	stats_dirty = true


func remove(id: StringName) -> void:
	for index: int in range(instances.size() - 1, -1, -1):
		if instances[index].definition.id != id:
			continue
		var instance := instances[index]
		instances.remove_at(index)
		conditional.erase(instance)
		if _aggregated_in_stats(instance.definition):
			stats_dirty = true


func tick() -> void:
	for index: int in range(instances.size() - 1, -1, -1):
		var instance := instances[index]
		if instance.remaining_ticks <= 0:
			continue
		instance.remaining_ticks -= 1
		if instance.remaining_ticks != 0:
			continue
		instances.remove_at(index)
		conditional.erase(instance)
		if _aggregated_in_stats(instance.definition):
			stats_dirty = true


func get_stats() -> CombatStats:
	if stats_dirty:
		rebuild()
	return stats


func rebuild() -> void:
	stats.reset()
	conditional.clear()
	for instance: ModifierInstance in instances:
		var definition := instance.definition
		if _appears_in_conditional(definition):
			conditional.append(instance)
		if _has_hit_condition(definition):
			continue
		for operation: ModifierOperation in definition.operations:
			if operation.required_attack_tags == 0:
				stats.apply_operation(operation, instance.stacks)
	for type: int in 2:
		stats.mitigation[type] = DefenseFormula.mitigation(stats.defense[type], stats.defense_constant)
	stats_dirty = false
	rebuild_count += 1


func apply_conditional(request: DamageRequest, source: CombatantState,
		target: CombatantState, attack_tags: int) -> void:
	for instance: ModifierInstance in conditional:
		var definition := instance.definition
		if not _matches(definition, source, target, attack_tags):
			continue
		var gated := _has_hit_condition(definition)
		for operation: ModifierOperation in definition.operations:
			if operation.required_attack_tags != 0:
				if attack_tags & operation.required_attack_tags == operation.required_attack_tags:
					CombatStats.apply_to_request(request, operation, instance.stacks)
			elif gated:
				CombatStats.apply_to_request(request, operation, instance.stacks)


func notify_after_damage(source: CombatantState, target: CombatantState, actual_damage: float) -> void:
	var snapshot := instances.duplicate()
	for instance: ModifierInstance in snapshot:
		var handler := instance.definition.after_damage_handler
		if handler != null:
			handler.after_damage(source, target, actual_damage)


func _matches(definition: ModifierDefinition, source: CombatantState,
		target: CombatantState, attack_tags: int) -> bool:
	if definition.required_attack_tags != 0 and \
		attack_tags & definition.required_attack_tags != definition.required_attack_tags:
		return false
	if definition.required_target_status != CombatTypes.Status.NONE and (target == null \
			or not target.statuses.has(definition.required_target_status)):
		return false
	if definition.target_hp_ratio_below < 1.0 and (target == null \
			or target.health_ratio() >= definition.target_hp_ratio_below):
		return false
	return true


static func _has_hit_condition(definition: ModifierDefinition) -> bool:
	return definition.required_attack_tags != 0 \
		or definition.required_target_status != CombatTypes.Status.NONE \
		or definition.target_hp_ratio_below < 1.0


static func _has_tagged_operation(definition: ModifierDefinition) -> bool:
	for operation: ModifierOperation in definition.operations:
		if operation.required_attack_tags != 0:
			return true
	return false


static func _appears_in_conditional(definition: ModifierDefinition) -> bool:
	return _has_hit_condition(definition) or _has_tagged_operation(definition)


static func _aggregated_in_stats(definition: ModifierDefinition) -> bool:
	if _has_hit_condition(definition):
		return false
	for operation: ModifierOperation in definition.operations:
		if operation.required_attack_tags == 0:
			return true
	return false


## Instances are kept sorted by (priority, sequence) at insertion time, so
## [rebuild] never needs to sort. Equal priorities keep insertion order
## because a fresh instance always has the highest sequence.
func _insertion_index(priority: int) -> int:
	var low := 0
	var high := instances.size()
	while low < high:
		var mid := (low + high) / 2
		if instances[mid].definition.priority <= priority:
			low = mid + 1
		else:
			high = mid
	return low
