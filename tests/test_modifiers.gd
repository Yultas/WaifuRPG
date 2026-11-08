extends SceneTree
## Run: godot --headless --path . -s res://tests/test_modifiers.gd

var _failures := 0


class CountingHandler:
	extends ModifierHandler

	var calls := 0
	var last_damage := 0.0

	func after_damage(_source: CombatantState, _target: CombatantState, actual_damage: float) -> void:
		calls += 1
		last_damage = actual_damage


class MutatingHandler:
	extends ModifierHandler

	var calls := 0
	var mutate: Callable
	var late_handler: CountingHandler

	func after_damage(_source: CombatantState, _target: CombatantState, _actual_damage: float) -> void:
		calls += 1
		if mutate.is_valid():
			mutate.call()


func _initialize() -> void:
	_test_lazy_rebuild()
	_test_stacks_and_cap()
	_test_reapply_without_stacks()
	_test_expiry()
	_test_stable_order()
	_test_status_condition()
	_test_mixed_operations_no_double_apply()
	_test_hp_ratio_condition()
	_test_after_damage_hook()
	_test_after_damage_mutation_during_callback()
	_test_null_target_conditions()
	_test_insertion_order_without_rebuild()
	_test_owner_isolation()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _make_definition(id: StringName, stat: CombatTypes.Stat, value: float,
		mask: int = 3, duration: float = 0.0, max_stacks: int = 1) -> ModifierDefinition:
	var operation := ModifierOperation.new()
	operation.stat = stat
	operation.value = value
	operation.damage_type_mask = mask
	var definition := ModifierDefinition.new()
	definition.id = id
	definition.operations = [operation]
	definition.duration = duration
	definition.max_stacks = max_stacks
	return definition


func _make_combatant(id: int) -> CombatantState:
	var definition := CombatantDefinition.new()
	definition.max_hp = 100.0
	var state := CombatantState.new()
	state.configure(definition, id, CombatTypes.Faction.ENEMY, StatusConfig.new())
	return state


func _test_lazy_rebuild() -> void:
	var set := ModifierSet.new()
	_expect_count("initial rebuild", set, 1)
	_expect_count("lazy rebuild stable", set, 1)
	set.add(_make_definition(&"flat", CombatTypes.Stat.FLAT_DAMAGE, 5.0))
	_expect_count("rebuild after add", set, 2)
	_expect_count("no rebuild without change", set, 2)
	_expect_count("still no rebuild", set, 2)
	_expect_stat("aggregated flat", set.stats.flat_bonus[CombatTypes.DamageType.PHYSICAL], 5.0)


func _test_stacks_and_cap() -> void:
	var set := ModifierSet.new()
	var definition := _make_definition(&"stacked", CombatTypes.Stat.FLAT_DAMAGE,
		5.0, 3, 0.0, 3)
	set.add(definition)
	set.add(definition)
	set.add(definition)
	_expect_stat("three stacks", set.get_stats().flat_bonus[CombatTypes.DamageType.PHYSICAL], 15.0)
	var count_after_cap_setup := set.rebuild_count
	set.add(definition)
	if set.instances[0].stacks != 3:
		_failures += 1
		printerr("stacks must cap at max_stacks: got %s" % set.instances[0].stacks)
	_expect_stat("capped stacks", set.get_stats().flat_bonus[CombatTypes.DamageType.PHYSICAL], 15.0)
	_expect_count("capped reapply does not rebuild", set, count_after_cap_setup)


func _test_reapply_without_stacks() -> void:
	var set := ModifierSet.new()
	var definition := _make_definition(&"refresh", CombatTypes.Stat.FLAT_DAMAGE,
		5.0, 3, 1.0)
	definition.adds_stack_on_reapply = false
	definition.refreshes_duration = true
	set.add(definition)
	set.get_stats()
	var count := set.rebuild_count
	for _index: int in 30:
		set.tick()
	if set.instances.is_empty():
		_failures += 1
		printerr("modifier must still be active before expiry")
	set.add(definition)
	if set.instances[0].remaining_ticks != 60:
		_failures += 1
		printerr("reapply must refresh duration: got %s ticks" % set.instances[0].remaining_ticks)
	_expect_count("refresh-only reapply does not rebuild", set, count)


func _test_expiry() -> void:
	var set := ModifierSet.new()
	set.add(_make_definition(&"temp", CombatTypes.Stat.FLAT_DAMAGE, 5.0, 3, 0.1))
	var stats := set.get_stats()
	_expect_stat("temporary flat", stats.flat_bonus[CombatTypes.DamageType.PHYSICAL], 5.0)
	var count := set.rebuild_count
	for _index: int in 5:
		set.tick()
	if set.instances.size() != 1:
		_failures += 1
		printerr("modifier must survive 5 of 6 ticks")
	_expect_count("no rebuild before expiry", set, count)
	set.tick()
	if not set.instances.is_empty():
		_failures += 1
		printerr("modifier must expire after its ticks run out")
	stats = set.get_stats()
	_expect_stat("expired flat removed", stats.flat_bonus[CombatTypes.DamageType.PHYSICAL], 0.0)
	_expect_count("expiry triggers one rebuild", set, count + 1)


func _test_stable_order() -> void:
	var set := ModifierSet.new()
	var a := _make_definition(&"a", CombatTypes.Stat.FLAT_DAMAGE, 1.0)
	var b := _make_definition(&"b", CombatTypes.Stat.FLAT_DAMAGE, 2.0)
	var c := _make_definition(&"c", CombatTypes.Stat.FLAT_DAMAGE, 3.0)
	c.priority = -1
	set.add(a)
	set.add(b)
	set.add(c)
	set.get_stats()
	var ids: Array[StringName] = []
	for instance: ModifierInstance in set.instances:
		ids.append(instance.definition.id)
	if ids != [&"c", &"a", &"b"]:
		_failures += 1
		printerr("stable order must sort by priority then sequence: got %s" % ids)


func _test_status_condition() -> void:
	var set := ModifierSet.new()
	var definition := _make_definition(&"burn_bonus", CombatTypes.Stat.FLAT_DAMAGE, 7.0)
	definition.required_target_status = CombatTypes.Status.BURN
	set.get_stats()
	set.add(definition)
	if set.stats_dirty:
		_failures += 1
		printerr("conditional-only add must not mark stats dirty")
	if set.conditional.size() != 1:
		_failures += 1
		printerr("conditional modifier must be indexed separately")
	_expect_stat("conditional not aggregated",
		set.get_stats().flat_bonus[CombatTypes.DamageType.PHYSICAL], 0.0)
	var source := _make_combatant(1)
	var target := _make_combatant(2)
	var request := DamageRequest.new()
	set.apply_conditional(request, source, target, CombatTypes.AttackTag.MELEE)
	_expect_stat("no burn, no bonus", request.flat_bonus, 0.0)
	target.statuses.apply(CombatTypes.Status.BURN, 1, -1)
	set.apply_conditional(request, source, target, CombatTypes.AttackTag.MELEE)
	_expect_stat("burning target bonus", request.flat_bonus, 7.0)


func _test_mixed_operations_no_double_apply() -> void:
	var set := ModifierSet.new()
	var definition := ModifierDefinition.new()
	definition.id = &"mixed"
	var flat := ModifierOperation.new()
	flat.stat = CombatTypes.Stat.FLAT_DAMAGE
	flat.value = 10.0
	var tagged := ModifierOperation.new()
	tagged.stat = CombatTypes.Stat.OUTGOING_ADDITIVE
	tagged.value = 0.5
	tagged.required_attack_tags = CombatTypes.AttackTag.MELEE
	definition.operations = [flat, tagged]
	set.add(definition)
	var stats := set.get_stats()
	_expect_stat("mixed flat aggregated once",
		stats.flat_bonus[CombatTypes.DamageType.PHYSICAL], 10.0)
	_expect_stat("tagged op not aggregated",
		stats.outgoing_additive[CombatTypes.DamageType.PHYSICAL], 0.0)
	if set.conditional.size() != 1:
		_failures += 1
		printerr("mixed definition must be indexed for per-hit operations")
	var source := _make_combatant(1)
	var target := _make_combatant(2)
	var request := DamageRequest.new()
	request.base_damage = 100.0
	request.flat_bonus = stats.flat_bonus[CombatTypes.DamageType.PHYSICAL]
	request.outgoing_additive = stats.outgoing_additive[CombatTypes.DamageType.PHYSICAL]
	set.apply_conditional(request, source, target, CombatTypes.AttackTag.MELEE)
	_expect_stat("unconditional op not reapplied per hit", request.flat_bonus, 10.0)
	_expect_stat("tagged op applied per hit", request.outgoing_additive, 0.5)
	var result := DamageResult.new()
	DamageCalculator.resolve_into(request, result)
	_expect_stat("melee damage", result.damage, 165.0)
	var other := DamageRequest.new()
	other.base_damage = 100.0
	other.flat_bonus = stats.flat_bonus[CombatTypes.DamageType.PHYSICAL]
	set.apply_conditional(other, source, target, CombatTypes.AttackTag.PROJECTILE)
	_expect_stat("untagged attack ignores tagged op", other.outgoing_additive, 0.0)
	_expect_count("per-hit checks never rebuild", set, set.rebuild_count)


func _test_hp_ratio_condition() -> void:
	var set := ModifierSet.new()
	var definition := _make_definition(&"executioner", CombatTypes.Stat.FLAT_DAMAGE, 3.0)
	definition.target_hp_ratio_below = 0.5
	set.add(definition)
	var source := _make_combatant(1)
	var target := _make_combatant(2)
	var request := DamageRequest.new()
	set.apply_conditional(request, source, target, CombatTypes.AttackTag.MELEE)
	_expect_stat("full hp target ignored", request.flat_bonus, 0.0)
	target.hp = 40.0
	set.apply_conditional(request, source, target, CombatTypes.AttackTag.MELEE)
	_expect_stat("low hp target bonus", request.flat_bonus, 3.0)


func _test_after_damage_hook() -> void:
	var set := ModifierSet.new()
	var definition := _make_definition(&"vampiric", CombatTypes.Stat.FLAT_DAMAGE, 0.0)
	var handler := CountingHandler.new()
	definition.after_damage_handler = handler
	set.add(definition)
	var source := _make_combatant(1)
	var target := _make_combatant(2)
	set.notify_after_damage(source, target, 12.5)
	if handler.calls != 1 or not is_equal_approx(handler.last_damage, 12.5):
		_failures += 1
		printerr("after_damage hook must fire once with actual damage: %s calls, %s" % [
			handler.calls, handler.last_damage])
	_expect_count("hooks do not trigger rebuild", set, 1)


func _test_after_damage_mutation_during_callback() -> void:
	var set := ModifierSet.new()
	var other_definition := _make_definition(&"other", CombatTypes.Stat.FLAT_DAMAGE, 0.0)
	other_definition.priority = 1
	var other_handler := CountingHandler.new()
	other_definition.after_damage_handler = other_handler
	var mutating_definition := _make_definition(&"mutating", CombatTypes.Stat.FLAT_DAMAGE, 0.0)
	mutating_definition.priority = -1
	var mutating_handler := MutatingHandler.new()
	mutating_handler.mutate = func() -> void:
		set.remove(&"other")
		if mutating_handler.late_handler == null:
			var late_definition := _make_definition(&"late", CombatTypes.Stat.FLAT_DAMAGE, 0.0)
			mutating_handler.late_handler = CountingHandler.new()
			late_definition.after_damage_handler = mutating_handler.late_handler
			set.add(late_definition)
	mutating_definition.after_damage_handler = mutating_handler
	set.add(other_definition)
	set.add(mutating_definition)
	var source := _make_combatant(1)
	var target := _make_combatant(2)
	set.notify_after_damage(source, target, 7.0)
	if mutating_handler.calls != 1:
		_failures += 1
		printerr("mutating hook must fire once, got %s" % mutating_handler.calls)
	if other_handler.calls != 1:
		_failures += 1
		printerr("removed-during-callback hook must still fire from snapshot, got %s" % [
			other_handler.calls])
	if mutating_handler.late_handler == null or mutating_handler.late_handler.calls != 0:
		_failures += 1
		printerr("modifier added during callback must not fire in the same pass")
	set.notify_after_damage(source, target, 7.0)
	if other_handler.calls != 1:
		_failures += 1
		printerr("removed modifier must not fire on the next pass, got %s" % other_handler.calls)
	if mutating_handler.late_handler == null or mutating_handler.late_handler.calls != 1:
		_failures += 1
		printerr("modifier added during callback must fire on the next pass")
	set.clear()
	mutating_handler.mutate = Callable()


func _test_null_target_conditions() -> void:
	var set := ModifierSet.new()
	var status_definition := _make_definition(&"burn_bonus", CombatTypes.Stat.FLAT_DAMAGE, 7.0)
	status_definition.required_target_status = CombatTypes.Status.BURN
	var ratio_definition := _make_definition(&"executioner", CombatTypes.Stat.FLAT_DAMAGE, 3.0)
	ratio_definition.target_hp_ratio_below = 0.5
	var tag_definition := _make_definition(&"melee_bonus", CombatTypes.Stat.FLAT_DAMAGE, 4.0)
	var tag_operation: ModifierOperation = tag_definition.operations[0]
	tag_operation.required_attack_tags = CombatTypes.AttackTag.MELEE
	set.add(status_definition)
	set.add(ratio_definition)
	set.add(tag_definition)
	var source := _make_combatant(1)
	var request := DamageRequest.new()
	set.apply_conditional(request, source, null, CombatTypes.AttackTag.MELEE)
	_expect_stat("null target skips status and hp conditions, tag-only op applies",
		request.flat_bonus, 4.0)


func _test_insertion_order_without_rebuild() -> void:
	var set := ModifierSet.new()
	var mid := _make_definition(&"mid", CombatTypes.Stat.FLAT_DAMAGE, 1.0)
	var high := _make_definition(&"high", CombatTypes.Stat.FLAT_DAMAGE, 1.0)
	high.priority = 5
	var mid_late := _make_definition(&"mid_late", CombatTypes.Stat.FLAT_DAMAGE, 1.0)
	var low := _make_definition(&"low", CombatTypes.Stat.FLAT_DAMAGE, 1.0)
	low.priority = -3
	var gated := _make_definition(&"gated", CombatTypes.Stat.FLAT_DAMAGE, 1.0)
	gated.priority = 2
	gated.required_target_status = CombatTypes.Status.BURN
	var gated_low := _make_definition(&"gated_low", CombatTypes.Stat.FLAT_DAMAGE, 1.0)
	gated_low.priority = -3
	gated_low.required_target_status = CombatTypes.Status.BURN
	set.add(mid)
	set.add(high)
	set.add(mid_late)
	set.add(low)
	set.add(gated)
	set.add(gated_low)
	_expect_ids("order maintained without rebuild", set.instances,
		[&"low", &"gated_low", &"mid", &"mid_late", &"gated", &"high"])
	_expect_ids("conditional follows priority order", set.conditional,
		[&"gated_low", &"gated"])
	var replay := ModifierSet.new()
	replay.add(mid)
	replay.add(high)
	replay.add(mid_late)
	replay.add(low)
	replay.add(gated)
	replay.add(gated_low)
	replay.get_stats()
	_expect_ids("same insertion sequence gives deterministic order", replay.instances,
		[&"low", &"gated_low", &"mid", &"mid_late", &"gated", &"high"])
	set.remove(&"mid_late")
	_expect_ids("order stable after removal", set.instances,
		[&"low", &"gated_low", &"mid", &"gated", &"high"])
	set.get_stats()
	_expect_ids("rebuild preserves insertion order", set.instances,
		[&"low", &"gated_low", &"mid", &"gated", &"high"])


func _test_owner_isolation() -> void:
	var first := ModifierSet.new()
	var second := ModifierSet.new()
	first.get_stats()
	second.get_stats()
	first.add(_make_definition(&"flat", CombatTypes.Stat.FLAT_DAMAGE, 5.0))
	first.get_stats()
	_expect_count("untouched owner not rebuilt", second, 1)


func _expect_stat(label: String, actual: float, expected: float) -> void:
	if not is_equal_approx(actual, expected):
		_failures += 1
		printerr("%s: expected %s, got %s" % [label, expected, actual])


func _expect_count(label: String, set: ModifierSet, expected: int) -> void:
	set.get_stats()
	if set.rebuild_count != expected:
		_failures += 1
		printerr("%s: expected %d rebuilds, got %d" % [label, expected, set.rebuild_count])


func _expect_ids(label: String, list: Array, expected: Array[StringName]) -> void:
	var ids: Array[StringName] = []
	for instance: ModifierInstance in list:
		ids.append(instance.definition.id)
	if ids != expected:
		_failures += 1
		printerr("%s: expected %s, got %s" % [label, expected, ids])
