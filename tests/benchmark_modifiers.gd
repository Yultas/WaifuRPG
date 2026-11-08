extends SceneTree
## Modifier pipeline benchmark: stat rebuild, cached get_stats, request fill/resolve,
## and per-hit conditional modifiers through DamageSystem.deal.
## Control values are checked after every series, so the benchmark also guards the math.
## Run: godot --headless --path . -s res://tests/benchmark_modifiers.gd
## Options: --iterations=100000 --rounds=5

const DEFAULT_ITERATIONS := 100_000
const DEFAULT_ROUNDS := 5
const WARMUP_CALLS := 10_000
const GET_STATS_CALLS := 10_000
const REBUILD_MODIFIER_COUNT := 100
const CONDITIONAL_COUNTS: Array[int] = [0, 10, 50]

var _failures := 0


func _initialize() -> void:
	var iterations := DEFAULT_ITERATIONS
	var rounds := DEFAULT_ROUNDS
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--iterations="):
			iterations = maxi(1, int(arg.get_slice("=", 1)))
		elif arg.begins_with("--rounds="):
			rounds = maxi(1, int(arg.get_slice("=", 1)))

	_benchmark_rebuild(iterations, rounds)
	_benchmark_get_stats(rounds)
	_benchmark_request_resolve(iterations, rounds)
	_benchmark_conditionals(iterations, rounds)
	print("ALL PASSED" if _failures == 0 else "FAILED: %d control problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _benchmark_rebuild(iterations: int, rounds: int) -> void:
	var set := ModifierSet.new()
	for index: int in REBUILD_MODIFIER_COUNT:
		set.add(_make_unconditional_definition(index))
	set.get_stats()
	for _warmup: int in 100:
		set.rebuild()
	print("ModifierSet.rebuild with %d unconditional modifiers: %s iterations, %d rounds" % [
		REBUILD_MODIFIER_COUNT, _format_number(iterations), rounds])
	var rates: Array[float] = []
	for round_index: int in rounds:
		var started := Time.get_ticks_usec()
		for _call: int in iterations:
			set.rebuild()
		rates.append(_print_round(round_index + 1, iterations,
			Time.get_ticks_usec() - started, "rebuild"))
	_print_median(rates, "rebuild")
	_expect(is_equal_approx(set.stats.flat_bonus[CombatTypes.DamageType.PHYSICAL], 100.0),
		"rebuild100 control: flat_bonus %s, expected 100" % [
			set.stats.flat_bonus[CombatTypes.DamageType.PHYSICAL]])
	_expect(is_equal_approx(set.stats.outgoing_additive[CombatTypes.DamageType.PHYSICAL], 1.0),
		"rebuild100 control: outgoing_additive %s, expected 1" % [
			set.stats.outgoing_additive[CombatTypes.DamageType.PHYSICAL]])
	_expect(is_equal_approx(set.stats.mitigation[CombatTypes.DamageType.PHYSICAL], 0.25),
		"rebuild100 control: mitigation %s, expected 0.25" % [
			set.stats.mitigation[CombatTypes.DamageType.PHYSICAL]])


func _benchmark_get_stats(rounds: int) -> void:
	var set := ModifierSet.new()
	for index: int in REBUILD_MODIFIER_COUNT:
		set.add(_make_unconditional_definition(index))
	set.get_stats()
	for _warmup: int in WARMUP_CALLS:
		set.get_stats()
	print("ModifierSet.get_stats, cache hit: %s calls x %d rounds, no rebuild allowed" % [
		_format_number(GET_STATS_CALLS), rounds])
	var rebuilds_before := set.rebuild_count
	var rates: Array[float] = []
	for round_index: int in rounds:
		var started := Time.get_ticks_usec()
		for _call: int in GET_STATS_CALLS:
			set.get_stats()
		rates.append(_print_round(round_index + 1, GET_STATS_CALLS,
			Time.get_ticks_usec() - started, "get_stats"))
	_print_median(rates, "get_stats")
	_expect(set.rebuild_count == rebuilds_before,
		"get_stats control: %d unexpected rebuild(s)" % [set.rebuild_count - rebuilds_before])
	_expect(is_equal_approx(set.stats.flat_bonus[CombatTypes.DamageType.PHYSICAL], 100.0),
		"get_stats control: flat_bonus %s, expected 100" % [
			set.stats.flat_bonus[CombatTypes.DamageType.PHYSICAL]])


func _benchmark_request_resolve(iterations: int, rounds: int) -> void:
	var source := _make_combatant(1, CombatTypes.Faction.HERO, 1000.0)
	var target := _make_combatant(2, CombatTypes.Faction.ENEMY, 1000.0)
	source.modifiers.add(_make_simple_definition(&"source_flat",
		CombatTypes.Stat.FLAT_DAMAGE, 5.0))
	source.modifiers.add(_make_simple_definition(&"source_additive",
		CombatTypes.Stat.OUTGOING_ADDITIVE, 0.5))
	source.modifiers.add(_make_simple_definition(&"source_multiplier",
		CombatTypes.Stat.OUTGOING_MULTIPLIER, 1.5))
	source.modifiers.get_stats()
	target.modifiers.get_stats()
	var attack := _make_attack(100.0)
	var request := DamageRequest.new()
	var result := DamageResult.new()
	var damage_type := attack.damage_type
	for _warmup: int in WARMUP_CALLS:
		request.reset()
		request.damage_type = damage_type
		request.base_damage = attack.base_damage
		var source_stats := source.modifiers.get_stats()
		request.flat_bonus += source_stats.flat_bonus[damage_type]
		request.outgoing_additive += source_stats.outgoing_additive[damage_type]
		request.outgoing_multiplier *= source_stats.outgoing_multiplier[damage_type]
		source.modifiers.apply_conditional(request, source, target, attack.tags)
		var target_stats := target.modifiers.get_stats()
		request.incoming_additive += target_stats.incoming_additive[damage_type]
		request.mitigation = target_stats.mitigation[damage_type]
		target.modifiers.apply_conditional(request, source, target, attack.tags)
		DamageCalculator.resolve_into(request, result)
	print("request fill (ready stats) + DamageCalculator.resolve_into: %s iterations, %d rounds" % [
		_format_number(iterations), rounds])
	var rates: Array[float] = []
	for round_index: int in rounds:
		var started := Time.get_ticks_usec()
		for _call: int in iterations:
			request.reset()
			request.damage_type = damage_type
			request.base_damage = attack.base_damage
			var source_stats := source.modifiers.get_stats()
			request.flat_bonus += source_stats.flat_bonus[damage_type]
			request.outgoing_additive += source_stats.outgoing_additive[damage_type]
			request.outgoing_multiplier *= source_stats.outgoing_multiplier[damage_type]
			source.modifiers.apply_conditional(request, source, target, attack.tags)
			var target_stats := target.modifiers.get_stats()
			request.incoming_additive += target_stats.incoming_additive[damage_type]
			request.mitigation = target_stats.mitigation[damage_type]
			target.modifiers.apply_conditional(request, source, target, attack.tags)
			DamageCalculator.resolve_into(request, result)
		rates.append(_print_round(round_index + 1, iterations,
			Time.get_ticks_usec() - started, "request"))
	_print_median(rates, "request")
	_expect(is_equal_approx(result.damage, 236.25),
		"request/resolve control: damage %s, expected 236.25" % result.damage)


func _benchmark_conditionals(iterations: int, rounds: int) -> void:
	for conditional_count: int in CONDITIONAL_COUNTS:
		var source := _make_combatant(101, CombatTypes.Faction.HERO, 1_000_000_000.0)
		var target := _make_combatant(102, CombatTypes.Faction.ENEMY, 1_000_000_000.0)
		for index: int in conditional_count:
			source.modifiers.add(_make_conditional_definition(index))
		source.modifiers.get_stats()
		target.modifiers.get_stats()
		var system := DamageSystem.new()
		system.register_combatant(source)
		system.register_combatant(target)
		var attack := _make_attack(1.0)
		var result := DamageResult.new()
		for _warmup: int in WARMUP_CALLS:
			system.deal(attack, source, target, result)
		print("DamageSystem.deal with %d conditional modifiers: %s iterations, %d rounds" % [
			conditional_count, _format_number(iterations), rounds])
		var rates: Array[float] = []
		for round_index: int in rounds:
			var started := Time.get_ticks_usec()
			for _call: int in iterations:
				system.deal(attack, source, target, result)
			rates.append(_print_round(round_index + 1, iterations,
				Time.get_ticks_usec() - started, "deal"))
		_print_median(rates, "deal")
		var expected := 1.0 + 2.0 * conditional_count
		_expect(is_equal_approx(result.damage, expected),
			"conditional control (%d): damage %s, expected %s" % [
				conditional_count, result.damage, expected])


func _make_unconditional_definition(index: int) -> ModifierDefinition:
	var definition := ModifierDefinition.new()
	definition.id = StringName("uncond_%d" % index)
	var flat := ModifierOperation.new()
	flat.stat = CombatTypes.Stat.FLAT_DAMAGE
	flat.value = 1.0
	var additive := ModifierOperation.new()
	additive.stat = CombatTypes.Stat.OUTGOING_ADDITIVE
	additive.value = 0.01
	var defense := ModifierOperation.new()
	defense.stat = CombatTypes.Stat.DEFENSE
	defense.value = 0.5
	definition.operations = [flat, additive, defense]
	return definition


func _make_simple_definition(id: StringName, stat: CombatTypes.Stat, value: float) -> ModifierDefinition:
	var operation := ModifierOperation.new()
	operation.stat = stat
	operation.value = value
	var definition := ModifierDefinition.new()
	definition.id = id
	definition.operations = [operation]
	return definition


func _make_conditional_definition(index: int) -> ModifierDefinition:
	var definition := ModifierDefinition.new()
	definition.id = StringName("cond_%d" % index)
	definition.required_attack_tags = CombatTypes.AttackTag.MELEE
	var flat := ModifierOperation.new()
	flat.stat = CombatTypes.Stat.FLAT_DAMAGE
	flat.value = 2.0
	definition.operations = [flat]
	return definition


func _make_combatant(id: int, faction: CombatTypes.Faction, max_hp: float) -> CombatantState:
	var definition := CombatantDefinition.new()
	definition.max_hp = max_hp
	definition.max_poise = 100.0
	var state := CombatantState.new()
	state.configure(definition, id, faction, StatusConfig.new(), 60)
	return state


func _make_attack(base_damage: float) -> AttackDefinition:
	var attack := AttackDefinition.new()
	attack.id = &"benchmark_attack"
	attack.damage_type = CombatTypes.DamageType.PHYSICAL
	attack.base_damage = base_damage
	attack.poise_damage = 0.0
	attack.tags = CombatTypes.AttackTag.MELEE
	return attack


func _print_round(round_index: int, iterations: int, elapsed_usec: int, unit: String) -> float:
	var rate := iterations / (elapsed_usec / 1_000_000.0)
	print("round %d: %.3f ms | %.0f %s/s | %.1f ns/%s" % [
		round_index, elapsed_usec / 1000.0, rate, unit,
		elapsed_usec * 1000.0 / iterations, unit])
	return rate


func _print_median(rates: Array[float], unit: String) -> void:
	rates.sort()
	var median := rates[rates.size() / 2]
	if rates.size() % 2 == 0:
		median = (rates[rates.size() / 2 - 1] + median) * 0.5
	print("median: %.0f %s/s | %.1f ns/%s" % [median, unit, 1_000_000_000.0 / median, unit])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)


func _format_number(value: int) -> String:
	var digits := str(value)
	var output := ""
	for index: int in digits.length():
		if index > 0 and (digits.length() - index) % 3 == 0:
			output += " "
		output += digits[index]
	return output
