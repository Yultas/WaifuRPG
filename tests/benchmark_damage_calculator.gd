extends SceneTree
## Run: godot --headless --path . -s res://tests/benchmark_damage_calculator.gd
## Options: --iterations=1000000 --rounds=5

const DEFAULT_ITERATIONS := 1_000_000
const DEFAULT_ROUNDS := 5
const WARMUP_CALLS := 10_000


func _initialize() -> void:
	var iterations := DEFAULT_ITERATIONS
	var rounds := DEFAULT_ROUNDS
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--iterations="):
			iterations = maxi(1, int(arg.get_slice("=", 1)))
		elif arg.begins_with("--rounds="):
			rounds = maxi(1, int(arg.get_slice("=", 1)))

	var request := DamageRequest.new()
	request.damage_type = CombatTypes.DamageType.MAGICAL
	request.base_damage = 100.0
	request.flat_bonus = 20.0
	request.outgoing_additive = 0.5
	request.outgoing_multiplier = 1.5
	request.incoming_additive = 0.25
	request.mitigation = 0.8
	request.poise_damage = 8.0
	var result := DamageResult.new()

	for _call: int in WARMUP_CALLS:
		DamageCalculator.resolve_into(request, result)

	print("DamageCalculator: %s iterations, %d rounds; request/result reused" % [
		_format_number(iterations), rounds])
	var rates: Array[float] = []
	for round_index: int in rounds:
		var started := Time.get_ticks_usec()
		for _call: int in iterations:
			DamageCalculator.resolve_into(request, result)
		var elapsed_usec := Time.get_ticks_usec() - started
		var elapsed_seconds := elapsed_usec / 1_000_000.0
		var rate := iterations / elapsed_seconds
		rates.append(rate)
		print("round %d: %.3f ms | %.0f calculations/s | %.1f ns/calculation" % [
			round_index + 1, elapsed_usec / 1000.0, rate, elapsed_usec * 1000.0 / iterations])

	rates.sort()
	var median := rates[rates.size() / 2]
	if rates.size() % 2 == 0:
		median = (rates[rates.size() / 2 - 1] + median) * 0.5
	print("median: %.0f calculations/s | %.1f ns/calculation" % [median, 1_000_000_000.0 / median])
	if not is_equal_approx(result.damage, 270.0):
		printerr("Unexpected benchmark result: %s" % result.damage)
		quit(1)
		return
	quit(0)


func _format_number(value: int) -> String:
	var digits := str(value)
	var output := ""
	for index: int in digits.length():
		if index > 0 and (digits.length() - index) % 3 == 0:
			output += " "
		output += digits[index]
	return output
