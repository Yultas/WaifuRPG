extends SceneTree
## Unit tests of HitRegistry repeat-hit rules: one-shot attacks, hit limits, cooldowns in
## combat ticks, unlimited hits, per-instance and per-target isolation, rollback of
## prevented hits, and cleanup.
## Run: godot --headless --path . -s res://tests/test_hit_registry.gd

var _failures := 0
var _registry: HitRegistry


func _initialize() -> void:
	_registry = HitRegistry.new()
	_test_one_shot_blocks_second_hit()
	_test_max_hits()
	_test_cooldown_ticks()
	_test_cooldown_and_max_hits_together()
	_test_unlimited_hits()
	_test_same_tick_never_double_hits()
	_test_instance_isolation()
	_test_rollback_restores_budget()
	_test_rollback_restores_previous_cooldown()
	_test_clear_attack()
	_test_clear_target()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_one_shot_blocks_second_hit() -> void:
	var r := HitRegistry.new()
	_expect_true(r.register_hit(1, 10, 0, 0, 1), "one-shot first hit")
	_expect_true(not r.register_hit(1, 10, 1, 0, 1), "one-shot second hit blocked")
	_expect_true(not r.register_hit(1, 10, 100, 0, 1), "one-shot hit blocked much later")


func _test_max_hits() -> void:
	var r := HitRegistry.new()
	_expect_true(r.register_hit(1, 10, 0, 0, 2), "max 2: first")
	_expect_true(r.register_hit(1, 10, 1, 0, 2), "max 2: second")
	_expect_true(not r.register_hit(1, 10, 2, 0, 2), "max 2: third blocked")
	_expect_true(r.hits_for(1, 10) == 2, "max 2: hits counted")


func _test_cooldown_ticks() -> void:
	var r := HitRegistry.new()
	# cooldown 30 ticks, unlimited hits
	_expect_true(r.register_hit(1, 10, 0, 30, 0), "cooldown: first")
	_expect_true(not r.register_hit(1, 10, 29, 30, 0), "cooldown: tick 29 blocked")
	_expect_true(r.register_hit(1, 10, 30, 30, 0), "cooldown: tick 30 allowed")
	_expect_true(not r.register_hit(1, 10, 59, 30, 0), "cooldown: tick 59 blocked")
	_expect_true(r.register_hit(1, 10, 60, 30, 0), "cooldown: tick 60 allowed")


func _test_cooldown_and_max_hits_together() -> void:
	var r := HitRegistry.new()
	# 0.5 s cooldown at 60 ticks/s = 30 ticks, max 3 hits
	_expect_true(r.register_hit(1, 10, 0, 30, 3), "combo: first")
	_expect_true(not r.register_hit(1, 10, 15, 30, 3), "combo: early repeat blocked")
	_expect_true(r.register_hit(1, 10, 30, 30, 3), "combo: second after cooldown")
	_expect_true(r.register_hit(1, 10, 60, 30, 3), "combo: third after cooldown")
	_expect_true(not r.register_hit(1, 10, 90, 30, 3), "combo: fourth blocked by max hits")


func _test_unlimited_hits() -> void:
	var r := HitRegistry.new()
	for i in 200:
		if not r.register_hit(1, 10, i, 1, 0):
			_fail("unlimited: hit %d blocked" % i)
			return
	_expect_true(r.hits_for(1, 10) == 200, "unlimited: all hits counted")


func _test_same_tick_never_double_hits() -> void:
	var r := HitRegistry.new()
	_expect_true(r.register_hit(1, 10, 5, 0, 0), "same tick: first")
	_expect_true(not r.register_hit(1, 10, 5, 0, 0), "same tick: duplicate blocked")


func _test_instance_isolation() -> void:
	var r := HitRegistry.new()
	_expect_true(r.register_hit(1, 10, 0, 0, 1), "isolation: instance 1 hit")
	_expect_true(not r.register_hit(1, 10, 1, 0, 1), "isolation: instance 1 blocked")
	_expect_true(r.register_hit(2, 10, 1, 0, 1), "isolation: instance 2 independent")
	_expect_true(r.register_hit(1, 11, 1, 0, 1), "isolation: other target independent")


func _test_rollback_restores_budget() -> void:
	var r := HitRegistry.new()
	_expect_true(r.register_hit(1, 10, 0, 0, 1), "rollback: hit registered")
	_expect_true(r.rollback_hit(1, 10), "rollback: success")
	_expect_true(r.hits_for(1, 10) == 0, "rollback: budget restored")
	_expect_true(r.attack_count() == 0, "rollback: empty record dropped")
	_expect_true(r.register_hit(1, 10, 0, 0, 1), "rollback: one-shot can hit again")
	_expect_true(not r.register_hit(1, 10, 1, 0, 1), "rollback: second hit still blocked")
	_expect_true(not r.rollback_hit(99, 10), "rollback: unknown attack is a no-op")
	_expect_true(not r.rollback_hit(1, 999), "rollback: unknown target is a no-op")


func _test_rollback_restores_previous_cooldown() -> void:
	var r := HitRegistry.new()
	_expect_true(r.register_hit(1, 10, 0, 30, 0), "rollback cd: first hit")
	_expect_true(r.register_hit(1, 10, 30, 30, 0), "rollback cd: second hit after cooldown")
	_expect_true(r.rollback_hit(1, 10), "rollback cd: second hit rolled back")
	_expect_true(not r.register_hit(1, 10, 15, 30, 0), "rollback cd: previous cooldown kept")
	_expect_true(r.register_hit(1, 10, 30, 30, 0), "rollback cd: tick 30 allowed again")
	_expect_true(r.hits_for(1, 10) == 2, "rollback cd: only committed hits counted")


func _test_clear_attack() -> void:
	var r := HitRegistry.new()
	r.register_hit(1, 10, 0, 0, 1)
	r.register_hit(2, 10, 0, 0, 1)
	r.clear_attack(1)
	_expect_true(r.attack_count() == 1, "clear: only other attack remains")
	_expect_true(r.register_hit(1, 10, 1, 0, 1), "clear: same instance id reusable after cleanup")
	_expect_true(not r.register_hit(2, 10, 1, 0, 1), "clear: other attack untouched")


func _test_clear_target() -> void:
	var r := HitRegistry.new()
	r.register_hit(1, 10, 0, 0, 1)
	r.register_hit(1, 11, 0, 0, 1)
	r.clear_target(10)
	_expect_true(r.register_hit(1, 10, 1, 0, 1), "clear target: removed target hit again")
	_expect_true(not r.register_hit(1, 11, 1, 0, 1), "clear target: other target untouched")


func _expect_true(condition: bool, label: String) -> void:
	if not condition:
		_fail(label)


func _fail(message: String) -> void:
	_failures += 1
	printerr(message)
