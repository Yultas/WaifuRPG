extends SceneTree
## Status effect tests: stacks, caps, refresh, DoT cadence and merging,
## damage types, chill/freeze, stun refresh, bleed parameters, configure resets.
## Run: godot --headless --path . -s res://tests/test_statuses.gd

const TICKS := 60

var _failures := 0
var _system := DamageSystem.new()


class DamageRecorder extends ModifierHandler:
	var calls: Array[float] = []

	func after_damage(_source: CombatantState, _target: CombatantState, actual_damage: float) -> void:
		calls.append(actual_damage)


func _initialize() -> void:
	_test_burn_stacks_cap_refresh()
	_test_burn_dot_merged_request()
	_test_dot_rates_and_two_statuses()
	_test_dot_damage_types()
	_test_dot_full_duration()
	_test_chill_and_freeze()
	_test_stun_refresh()
	_test_bleed_parameters()
	_test_reconfigure_clears_statuses()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_burn_stacks_cap_refresh() -> void:
	var state := _make_state(1)
	state.statuses.apply(CombatTypes.Status.BURN, 3, 7)
	_expect(state.statuses.stacks_of(CombatTypes.Status.BURN) == 3,
		"burn: stacks %s, expected 3" % state.statuses.stacks_of(CombatTypes.Status.BURN))
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.BURN] == 180,
		"burn: duration %s ticks, expected 180" % state.statuses.remaining_ticks[CombatTypes.Status.BURN])
	state.statuses.apply(CombatTypes.Status.BURN, 7, 8)
	_expect(state.statuses.stacks_of(CombatTypes.Status.BURN) == 5,
		"burn cap: stacks %s, expected 5" % state.statuses.stacks_of(CombatTypes.Status.BURN))
	_expect(state.statuses.source_ids[CombatTypes.Status.BURN] == 8,
		"burn: source id %s, expected 8" % state.statuses.source_ids[CombatTypes.Status.BURN])
	_tick(state, 100)
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.BURN] == 80,
		"burn: remaining %s ticks after 100, expected 80" % state.statuses.remaining_ticks[CombatTypes.Status.BURN])
	state.statuses.apply(CombatTypes.Status.BURN, 1, 9)
	_expect(state.statuses.stacks_of(CombatTypes.Status.BURN) == 5,
		"burn reapply cap: stacks %s, expected 5" % state.statuses.stacks_of(CombatTypes.Status.BURN))
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.BURN] == 180,
		"burn reapply: duration not refreshed to 180")


func _test_burn_dot_merged_request() -> void:
	var source := _make_state(2, 1000.0, CombatTypes.Faction.HERO)
	var target := _make_state(3)
	_system.register_combatant(source)
	_system.register_combatant(target)
	var recorder := _attach_recorder(target)
	var hp_before := target.hp
	target.statuses.apply(CombatTypes.Status.BURN, 3, source.actor_id)
	_tick(target, 15)
	_expect(recorder.calls.size() == 1,
		"burn merged: %s requests per interval, expected 1" % recorder.calls.size())
	_expect(is_equal_approx(recorder.calls[0], 3.75),
		"burn merged: tick damage %s, expected 3.75" % recorder.calls[0])
	_expect(is_equal_approx(hp_before - target.hp, 3.75),
		"burn merged: hp delta %s, expected 3.75" % [hp_before - target.hp])
	_tick(target, 15)
	_expect(recorder.calls.size() == 2,
		"burn cadence: %s requests after 2 intervals, expected 2" % recorder.calls.size())


func _test_dot_rates_and_two_statuses() -> void:
	var target := _make_state(4)
	_system.register_combatant(target)
	var recorder := _attach_recorder(target)
	target.statuses.apply(CombatTypes.Status.BURN, 1, -1)
	target.statuses.apply(CombatTypes.Status.POISON, 1, -1)
	_tick(target, TICKS)
	_expect(recorder.calls.size() == 8,
		"dot: %s requests in 1 s, expected 8 (4 intervals x 2 statuses)" % recorder.calls.size())
	_expect(is_equal_approx(1000.0 - target.hp, 7.0),
		"dot: 1 s damage %s, expected 7.0 (burn 5 + poison 2)" % [1000.0 - target.hp])


func _test_dot_damage_types() -> void:
	var burn_target := _make_state(5)
	burn_target.modifiers.stats.base_defense[CombatTypes.DamageType.MAGICAL] = 10.0
	burn_target.modifiers.stats_dirty = true
	_system.register_combatant(burn_target)
	burn_target.statuses.apply(CombatTypes.Status.BURN, 1, -1)
	_tick(burn_target, 15)
	var burn_expected := 1.25 * DefenseFormula.mitigation(10.0, 0.06)
	_expect(is_equal_approx(1000.0 - burn_target.hp, burn_expected),
		"burn type: damage %s, expected magical vs defense 10 (%s)" % [1000.0 - burn_target.hp, burn_expected])
	var poison_target := _make_state(6)
	poison_target.modifiers.stats.base_defense[CombatTypes.DamageType.MAGICAL] = 10.0
	poison_target.modifiers.stats_dirty = true
	_system.register_combatant(poison_target)
	poison_target.statuses.apply(CombatTypes.Status.POISON, 1, -1)
	_tick(poison_target, 15)
	_expect(is_equal_approx(1000.0 - poison_target.hp, 0.5),
		"poison type: damage %s, expected 0.5 (physical, defense ignored)" % [1000.0 - poison_target.hp])


func _test_dot_full_duration() -> void:
	var target := _make_state(7)
	_system.register_combatant(target)
	var recorder := _attach_recorder(target)
	target.statuses.apply(CombatTypes.Status.BURN, 1, -1)
	_tick(target, 180)
	_expect(not target.statuses.has(CombatTypes.Status.BURN), "burn: still active after 3 s")
	_expect(is_equal_approx(1000.0 - target.hp, 15.0),
		"burn total: %s, expected 15.0 over full duration" % [1000.0 - target.hp])
	target.statuses.apply(CombatTypes.Status.POISON, 1, -1)
	_tick(target, 360)
	_expect(not target.statuses.has(CombatTypes.Status.POISON), "poison: still active after 6 s")
	_expect(is_equal_approx(1000.0 - target.hp, 27.0),
		"dot total: %s, expected 27.0 (burn 15 + poison 12)" % [1000.0 - target.hp])
	_expect(recorder.calls.size() == 36,
		"dot pulses: %s, expected 36 (burn 12 + poison 24)" % recorder.calls.size())


func _test_chill_and_freeze() -> void:
	var state := _make_state(8)
	state.statuses.apply(CombatTypes.Status.CHILL, 4)
	_expect(is_equal_approx(state.movement_multiplier(), 0.8),
		"chill: multiplier %s, expected 0.8" % state.movement_multiplier())
	_expect(state.can_act(), "chill: cannot act at 4 stacks")
	state.statuses.apply(CombatTypes.Status.CHILL, 5)
	_expect(state.statuses.stacks_of(CombatTypes.Status.CHILL) == 9,
		"chill: stacks %s, expected 9" % state.statuses.stacks_of(CombatTypes.Status.CHILL))
	_expect(is_equal_approx(state.movement_multiplier(), 0.55),
		"chill: multiplier %s, expected 0.55" % state.movement_multiplier())
	state.statuses.apply(CombatTypes.Status.CHILL, 1)
	_expect(not state.statuses.has(CombatTypes.Status.CHILL),
		"freeze: chill stacks not cleared")
	_expect(state.statuses.has(CombatTypes.Status.FREEZE), "freeze: not applied at 10 chill stacks")
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.FREEZE] == 60,
		"freeze: duration %s ticks, expected 60" % state.statuses.remaining_ticks[CombatTypes.Status.FREEZE])
	_expect(not state.can_act(), "freeze: can act")
	_expect(is_equal_approx(state.movement_multiplier(), 0.0),
		"freeze: movement multiplier %s, expected 0" % state.movement_multiplier())
	_tick(state, 60)
	_expect(not state.statuses.has(CombatTypes.Status.FREEZE), "freeze: still active after 1 s")
	_expect(state.can_act(), "freeze: cannot act after expiry")
	_expect(is_equal_approx(state.movement_multiplier(), 1.0),
		"freeze: movement multiplier %s after expiry" % state.movement_multiplier())


func _test_stun_refresh() -> void:
	var state := _make_state(9)
	state.statuses.apply(CombatTypes.Status.STUN)
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.STUN] == 24,
		"stun: duration %s ticks, expected 24" % state.statuses.remaining_ticks[CombatTypes.Status.STUN])
	_expect(not state.can_act(), "stun: can act")
	_tick(state, 20)
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.STUN] == 4,
		"stun: remaining %s ticks after 20, expected 4" % state.statuses.remaining_ticks[CombatTypes.Status.STUN])
	state.statuses.apply(CombatTypes.Status.STUN)
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.STUN] == 24,
		"stun refresh: remaining %s, expected refreshed 24, not summed 28" % state.statuses.remaining_ticks[CombatTypes.Status.STUN])
	_tick(state, 24)
	_expect(not state.statuses.has(CombatTypes.Status.STUN), "stun: still active after refresh window")


func _test_bleed_parameters() -> void:
	var state := _make_state(10)
	state.statuses.apply(CombatTypes.Status.BLEED, 12)
	_expect(state.statuses.stacks_of(CombatTypes.Status.BLEED) == 10,
		"bleed cap: stacks %s, expected 10" % state.statuses.stacks_of(CombatTypes.Status.BLEED))
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.BLEED] == 240,
		"bleed: duration %s ticks, expected 240" % state.statuses.remaining_ticks[CombatTypes.Status.BLEED])
	_tick(state, 239)
	_expect(state.statuses.has(CombatTypes.Status.BLEED), "bleed: expired early")
	_tick(state, 1)
	_expect(not state.statuses.has(CombatTypes.Status.BLEED), "bleed: still active after 4 s")


func _test_reconfigure_clears_statuses() -> void:
	var state := _make_state(11)
	state.statuses.apply(CombatTypes.Status.BURN, 3, 5)
	_tick(state, 10)
	var definition := CombatantDefinition.new()
	definition.max_hp = 500.0
	definition.max_poise = 100.0
	state.configure(definition, 12, CombatTypes.Faction.HERO, StatusConfig.new(), TICKS)
	_expect(state.statuses.stacks_of(CombatTypes.Status.BURN) == 0,
		"reconfigure: burn stacks %s, expected 0" % state.statuses.stacks_of(CombatTypes.Status.BURN))
	_expect(state.statuses.remaining_ticks[CombatTypes.Status.BURN] == 0,
		"reconfigure: burn duration kept")
	_expect(state.statuses.source_ids[CombatTypes.Status.BURN] == -1,
		"reconfigure: burn source %s, expected -1" % state.statuses.source_ids[CombatTypes.Status.BURN])
	_expect(is_equal_approx(state.hp, 500.0),
		"reconfigure: hp %s, expected full 500" % state.hp)
	# DoT cadence restarts from a full interval with the new source id.
	_system.register_combatant(state)
	state.statuses.apply(CombatTypes.Status.BURN, 1, -1)
	_tick(state, 14)
	_expect(is_equal_approx(state.hp, 500.0),
		"reconfigure: stale DoT cadence ticked early, hp %s" % state.hp)
	_tick(state, 1)
	_expect(is_equal_approx(500.0 - state.hp, 1.25),
		"reconfigure: fresh burn damage %s, expected 1.25" % [500.0 - state.hp])


func _make_state(id: int, hp := 1000.0, faction: CombatTypes.Faction = CombatTypes.Faction.ENEMY) -> CombatantState:
	var definition := CombatantDefinition.new()
	definition.max_hp = hp
	definition.max_poise = 100.0
	var state := CombatantState.new()
	state.configure(definition, id, faction, StatusConfig.new(), TICKS)
	return state


func _attach_recorder(state: CombatantState) -> DamageRecorder:
	var recorder := DamageRecorder.new()
	var definition := ModifierDefinition.new()
	definition.id = &"damage_recorder"
	definition.duration = 0.0
	definition.after_damage_handler = recorder
	state.modifiers.add(definition)
	return recorder


func _tick(state: CombatantState, count: int) -> void:
	for _i in count:
		state.tick(_system)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
