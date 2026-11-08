extends SceneTree
## Run: godot --headless --path . -s res://tests/test_damage_calculator.gd

var _failures := 0


func _initialize() -> void:
	_test_plain_hit()
	_test_full_pipeline()
	_test_negative_values()
	_test_mitigation_bounds()
	_test_negative_defense_vulnerability()
	_test_result_reuse()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_plain_hit() -> void:
	var request := DamageRequest.new()
	request.base_damage = 25.0
	request.poise_damage = 4.0
	_check("plain hit", request, 25.0, 4.0)


func _test_full_pipeline() -> void:
	var request := DamageRequest.new()
	request.damage_type = CombatTypes.DamageType.MAGICAL
	request.base_damage = 100.0
	request.flat_bonus = 20.0
	request.outgoing_additive = 0.5
	request.outgoing_multiplier = 1.5
	request.incoming_additive = 0.25
	request.mitigation = 0.8
	request.poise_damage = 8.0
	_check("full pipeline", request, 270.0, 8.0, CombatTypes.DamageType.MAGICAL)


func _test_negative_values() -> void:
	var request := DamageRequest.new()
	request.base_damage = 10.0
	request.flat_bonus = -30.0
	request.outgoing_multiplier = 2.0
	request.incoming_additive = 1.0
	request.poise_damage = -5.0
	_check("negative base", request, 0.0, 0.0)

	request.base_damage = 10.0
	request.flat_bonus = 0.0
	request.outgoing_additive = -2.0
	_check("negative outgoing", request, 0.0, 0.0)

	request.outgoing_additive = 0.0
	request.outgoing_multiplier = -1.0
	_check("negative special multiplier", request, 0.0, 0.0)


func _test_mitigation_bounds() -> void:
	var request := DamageRequest.new()
	request.base_damage = 40.0
	request.mitigation = -1.0
	_check("immunity", request, 0.0, 0.0)
	request.mitigation = 2.0
	_check("mitigation upper bound", request, 80.0, 0.0)


func _test_negative_defense_vulnerability() -> void:
	var request := DamageRequest.new()
	request.base_damage = 40.0
	request.mitigation = DefenseFormula.mitigation(-500.0)
	var result := DamageResult.new()
	DamageCalculator.resolve_into(request, result)
	if request.mitigation <= 1.0:
		_failures += 1
		printerr("negative defense must raise mitigation above 1: got %s" % request.mitigation)
	if result.damage <= 40.0 or result.damage > 80.0:
		_failures += 1
		printerr("negative defense must raise damage up to 200%%: got %s" % result.damage)
	_expect("negative defense damage", result.damage, 40.0 * request.mitigation)


func _test_result_reuse() -> void:
	var request := DamageRequest.new()
	request.base_damage = 50.0
	request.poise_damage = 6.0
	request.damage_type = CombatTypes.DamageType.MAGICAL
	var result := DamageResult.new()
	DamageCalculator.resolve_into(request, result)
	request.base_damage = 0.0
	request.poise_damage = 0.0
	request.damage_type = CombatTypes.DamageType.PHYSICAL
	DamageCalculator.resolve_into(request, result)
	_expect("reused damage", result.damage, 0.0)
	_expect("reused poise", result.poise_damage, 0.0)
	if result.damage_type != CombatTypes.DamageType.PHYSICAL:
		_failures += 1
		printerr("reused type: expected PHYSICAL, got %s" % result.damage_type)


func _check(label: String, request: DamageRequest, expected_damage: float,
		expected_poise: float, expected_type: CombatTypes.DamageType = CombatTypes.DamageType.PHYSICAL) -> void:
	var result := DamageResult.new()
	DamageCalculator.resolve_into(request, result)
	_expect(label + " damage", result.damage, expected_damage)
	_expect(label + " poise", result.poise_damage, expected_poise)
	if result.damage_type != expected_type:
		_failures += 1
		printerr("%s type: expected %s, got %s" % [label, expected_type, result.damage_type])


func _expect(label: String, actual: float, expected: float) -> void:
	if not is_equal_approx(actual, expected):
		_failures += 1
		printerr("%s: expected %s, got %s" % [label, expected, actual])
