extends SceneTree
## Run: godot --headless --path . -s res://tests/test_defense_formula.gd

var _failures := 0


func _initialize() -> void:
	_test_zero_defense()
	_test_positive_defense()
	_test_negative_defense()
	_test_extremes()
	_test_monotonic_range()
	_test_degenerate_constant()
	_test_damage_integration()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_zero_defense() -> void:
	_expect("zero defense", DefenseFormula.mitigation(0.0), 1.0)


func _test_positive_defense() -> void:
	_expect("defense 10", DefenseFormula.mitigation(10.0), 0.625)
	_expect("defense 100", DefenseFormula.mitigation(100.0), 1.0 - 6.0 / 7.0)


func _test_negative_defense() -> void:
	var weak := DefenseFormula.mitigation(-10.0)
	_expect("defense -10", weak, 1.375)
	if weak <= 1.0:
		_failures += 1
		printerr("negative defense must increase damage: got %s" % weak)
	var very_weak := DefenseFormula.mitigation(-100.0)
	_expect("defense -100", very_weak, 1.0 + 6.0 / 7.0)
	if very_weak <= weak:
		_failures += 1
		printerr("more negative defense must amplify more: %s vs %s" % [very_weak, weak])


func _test_extremes() -> void:
	var huge := DefenseFormula.mitigation(1.0e7)
	if huge <= 0.0 or huge >= 1.0:
		_failures += 1
		printerr("huge defense must approach 0 from above: got %s" % huge)
	var huge_negative := DefenseFormula.mitigation(-1.0e7)
	if huge_negative <= 1.0 or huge_negative >= 2.0:
		_failures += 1
		printerr("huge negative defense must approach 2 from below: got %s" % huge_negative)


func _test_monotonic_range() -> void:
	var previous := 2.0
	for defense: int in range(-1000, 1001, 7):
		var value := DefenseFormula.mitigation(float(defense))
		if value < 0.0 or value > 2.0:
			_failures += 1
			printerr("out of range 0..2 at defense %d: %s" % [defense, value])
			return
		if value > previous:
			_failures += 1
			printerr("not monotonic at defense %d: %s after %s" % [defense, value, previous])
			return
		previous = value


func _test_degenerate_constant() -> void:
	_expect("zero constant", DefenseFormula.mitigation(50.0, 0.0), 1.0)
	_expect("negative constant", DefenseFormula.mitigation(50.0, -5.0), 1.0)


func _test_damage_integration() -> void:
	var request := DamageRequest.new()
	request.base_damage = 50.0
	request.mitigation = DefenseFormula.mitigation(-1000.0)
	var result := DamageResult.new()
	DamageCalculator.resolve_into(request, result)
	if request.mitigation <= 1.0:
		_failures += 1
		printerr("negative defense must yield mitigation above 1: %s" % request.mitigation)
	if result.damage <= 50.0 or result.damage > 100.0:
		_failures += 1
		printerr("negative defense must raise damage above base up to 200%%: %s" % result.damage)
	_expect("negative defense exact", result.damage, 50.0 * request.mitigation)


func _expect(label: String, actual: float, expected: float) -> void:
	if not is_equal_approx(actual, expected):
		_failures += 1
		printerr("%s: expected %s, got %s" % [label, expected, actual])
