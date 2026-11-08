extends SceneTree
## Pure state/tick tests: no scene, navigation map, physics body or combat registry.
## Run: godot --headless --path . -s res://tests/test_enemy_brain.gd

const Brain := preload("res://src/enemies/enemy_brain.gd")
const DETECTION_M := 8.0
const ATTACK_M := 1.5
const WINDUP_TICKS := 3
const RECOVERY_TICKS := 4

var _failures := 0
var _assertions := 0


func _initialize() -> void:
	_test_detection_and_chase_boundaries()
	_test_full_windup_and_single_strike()
	_test_full_cooldown_after_miss()
	_test_cooldown_destinations()
	_test_pause_gate()
	_test_reset_and_independence()
	_test_minimum_action_ticks()
	print("Assertions: %d" % _assertions)
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_detection_and_chase_boundaries() -> void:
	var brain := Brain.new()
	_expect(_tick(brain, INF) == Brain.Intent.NONE, "missing target: emitted intent")
	_expect(brain.state == Brain.State.IDLE, "missing target: left idle")
	_tick(brain, DETECTION_M + 0.001)
	_expect(brain.state == Brain.State.IDLE, "outside detection: left idle")
	_expect(_tick(brain, DETECTION_M) == Brain.Intent.NONE,
			"detection boundary: moved on transition tick")
	_expect(brain.state == Brain.State.CHASE, "detection boundary: did not chase")
	_expect(_tick(brain, ATTACK_M + 0.001) == Brain.Intent.CHASE,
			"outside attack: did not request chase")
	_expect(_tick(brain, DETECTION_M + 0.001) == Brain.Intent.NONE,
			"lost target: kept moving")
	_expect(brain.state == Brain.State.IDLE, "lost target: did not idle")
	_tick(brain, ATTACK_M)
	_expect(brain.state == Brain.State.CHASE, "near target: skipped initial chase")
	_expect(_tick(brain, ATTACK_M) == Brain.Intent.NONE, "attack entry: moved")
	_expect(brain.state == Brain.State.TELEGRAPH, "attack boundary: no telegraph")
	_expect(brain.telegraph_ticks == WINDUP_TICKS, "attack entry: consumed windup tick")


func _test_full_windup_and_single_strike() -> void:
	var brain := _telegraphing()
	for remaining in range(WINDUP_TICKS - 1, 0, -1):
		_expect(_tick(brain, ATTACK_M) == Brain.Intent.NONE, "windup: early action")
		_expect(brain.telegraph_ticks == remaining, "windup: wrong remaining ticks")
		_expect(brain.state == Brain.State.TELEGRAPH, "windup: left early")
	_expect(_tick(brain, ATTACK_M) == Brain.Intent.STRIKE, "windup: no final strike")
	_expect(brain.telegraph_ticks == 0, "strike: windup did not reach zero")
	_expect(brain.state == Brain.State.TELEGRAPH, "strike: callback state changed early")
	brain.finish_strike(RECOVERY_TICKS)
	_expect(brain.state == Brain.State.COOLDOWN, "strike: no recovery")
	_expect(brain.cooldown_ticks == RECOVERY_TICKS, "strike: recovery tick consumed early")
	for _i in RECOVERY_TICKS:
		_expect(_tick(brain, ATTACK_M) != Brain.Intent.STRIKE, "recovery: extra strike")
	_expect(brain.state == Brain.State.TELEGRAPH, "recovery end: no new windup")
	_expect(brain.telegraph_ticks == WINDUP_TICKS, "recovery end: windup consumed early")


func _test_full_cooldown_after_miss() -> void:
	var brain := _telegraphing()
	for _i in WINDUP_TICKS - 1:
		_expect(_tick(brain, INF) == Brain.Intent.NONE, "miss: windup cancelled")
	_expect(_tick(brain, INF) == Brain.Intent.STRIKE, "miss: no strike attempt")
	brain.finish_strike(RECOVERY_TICKS)
	for remaining in range(RECOVERY_TICKS - 1, 0, -1):
		_expect(_tick(brain, INF) == Brain.Intent.NONE, "miss recovery: emitted action")
		_expect(brain.state == Brain.State.COOLDOWN, "miss recovery: left early")
		_expect(brain.cooldown_ticks == remaining, "miss recovery: wrong remaining ticks")
	_tick(brain, INF)
	_expect(brain.state == Brain.State.IDLE, "miss recovery: did not idle at expiry")


func _test_cooldown_destinations() -> void:
	for distance: float in [ATTACK_M, DETECTION_M, DETECTION_M + 0.001]:
		var brain := _telegraphing()
		for _i in WINDUP_TICKS:
			_tick(brain, distance)
		brain.finish_strike(1)
		_expect(_tick(brain, distance) == Brain.Intent.NONE, "recovery expiry: moved")
		var expected := Brain.State.IDLE
		if distance <= ATTACK_M:
			expected = Brain.State.TELEGRAPH
		elif distance <= DETECTION_M:
			expected = Brain.State.CHASE
		_expect(brain.state == expected, "recovery expiry: wrong destination at %s" % distance)


func _test_pause_gate() -> void:
	var brain := Brain.new()
	_expect(_tick(brain, ATTACK_M, false) == Brain.Intent.NONE, "paused idle: intent")
	_expect(brain.state == Brain.State.IDLE, "paused idle: changed state")
	_tick(brain, ATTACK_M)
	_expect(_tick(brain, ATTACK_M, false) == Brain.Intent.NONE, "paused chase: intent")
	_expect(brain.state == Brain.State.CHASE, "paused chase: changed state")
	_tick(brain, ATTACK_M)
	for _i in 5:
		_expect(_tick(brain, ATTACK_M, false) == Brain.Intent.NONE, "paused windup: intent")
	_expect(brain.telegraph_ticks == WINDUP_TICKS, "paused windup: timer advanced")
	for _i in WINDUP_TICKS:
		_tick(brain, ATTACK_M)
	brain.finish_strike(RECOVERY_TICKS)
	for _i in 5:
		_expect(_tick(brain, INF, false) == Brain.Intent.NONE, "paused recovery: intent")
	_expect(brain.cooldown_ticks == RECOVERY_TICKS, "paused recovery: timer advanced")
	_expect(brain.state == Brain.State.COOLDOWN, "paused recovery: changed state")


func _test_reset_and_independence() -> void:
	var first := _telegraphing()
	var second := _telegraphing()
	_tick(first, ATTACK_M)
	_expect(second.telegraph_ticks == WINDUP_TICKS, "instances: shared windup")
	for _i in WINDUP_TICKS - 1:
		_tick(first, ATTACK_M)
	first.finish_strike(RECOVERY_TICKS)
	_tick(first, ATTACK_M)
	_expect(second.state == Brain.State.TELEGRAPH, "instances: shared state")
	_expect(second.cooldown_ticks == 0, "instances: shared recovery")
	first.reset()
	_expect(first.state == Brain.State.IDLE, "reset: state not idle")
	_expect(first.telegraph_ticks == 0 and first.telegraph_total == 0,
			"reset: windup data retained")
	_expect(first.cooldown_ticks == 0, "reset: recovery retained")
	_expect(second.telegraph_ticks == WINDUP_TICKS, "reset: changed other instance")


func _test_minimum_action_ticks() -> void:
	var brain := Brain.new()
	brain.tick(ATTACK_M, DETECTION_M, ATTACK_M, 0)
	brain.tick(ATTACK_M, DETECTION_M, ATTACK_M, 0)
	_expect(brain.telegraph_ticks == 1, "minimum: zero-tick windup")
	_expect(brain.tick(ATTACK_M, DETECTION_M, ATTACK_M, 0) == Brain.Intent.STRIKE,
			"minimum: no strike after one tick")
	brain.finish_strike(0)
	_expect(brain.cooldown_ticks == 1, "minimum: zero-tick recovery")


func _telegraphing() -> EnemyBrain:
	var brain := Brain.new()
	_tick(brain, ATTACK_M)
	_tick(brain, ATTACK_M)
	return brain


func _tick(brain: EnemyBrain, distance_m: float, can_act := true) -> EnemyBrain.Intent:
	return brain.tick(distance_m, DETECTION_M, ATTACK_M, WINDUP_TICKS, can_act)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures += 1
		printerr(message)
