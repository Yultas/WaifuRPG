extends SceneTree
## DamageSystem tests: direct hits, actual damage, death, i-frames, friendly fire,
## poise, stagger, poise regen, hitstop, on-hit status applications,
## after-damage notifications, bleed amplification, DoT kills and source attribution,
## configure resets, DoT hitstop/bleed rules, bounded secondary-damage queue.
## Run: godot --headless --path . -s res://tests/test_damage_system.gd

const TICKS := 60

var _failures := 0
var _system := DamageSystem.new()
var _registered: Array[CombatantState] = []
var _handlers: Array = []


class DamageRecorder extends ModifierHandler:
	var calls: Array[float] = []

	func after_damage(_source: CombatantState, _target: CombatantState, actual_damage: float) -> void:
		calls.append(actual_damage)


class RetaliationHandler extends ModifierHandler:
	var system: DamageSystem
	var attack: AttackDefinition
	var armed := true

	func after_damage(source: CombatantState, target: CombatantState, _actual_damage: float) -> void:
		if not armed:
			return
		armed = false
		system.queue_hit(attack, target, source)


class SelfQueueHandler extends ModifierHandler:
	var system: DamageSystem
	var attack: AttackDefinition

	func after_damage(source: CombatantState, target: CombatantState, _actual_damage: float) -> void:
		# deal() called directly from a handler must defer instead of recursing.
		system.deal(attack, source, target, DamageResult.new())


func _initialize() -> void:
	_test_hit_and_death()
	_test_prevented_hits()
	_test_iframes_expire()
	_test_poise_stagger()
	_test_poise_regen()
	_test_hitstop()
	_test_status_applications_on_hit()
	_test_after_damage_notifications()
	_test_bleed_incoming()
	_test_dot_kill_and_source()
	_test_dot_source_resolution()
	_test_heal_and_health_ratio()
	_test_reconfigure_resets_state()
	_test_dot_no_hitstop_and_no_bleed_amp()
	_test_queued_secondary_damage()
	_test_bounded_queue_from_handler_deal()
	_test_knockback_distance_and_decay()
	_test_knockback_requires_distance_and_direction()
	_test_knockback_prevented_and_dot()
	_test_knockback_not_applied_to_dead()
	_cleanup()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_hit_and_death() -> void:
	var hero := _make_state(1, 10.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(2, 10.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(20.0)
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_expect(is_equal_approx(result.damage, 20.0), "hit: damage %s, expected 20" % result.damage)
	_expect(is_equal_approx(result.actual_damage, 10.0),
		"hit: actual %s, expected clamped 10" % result.actual_damage)
	_expect(result.target_died, "hit: target_died not set")
	_expect(not enemy.alive, "hit: enemy still alive")
	_expect(is_zero_approx(enemy.hp), "hit: hp %s, expected 0" % enemy.hp)
	var second := DamageResult.new()
	_system.deal(attack, hero, enemy, second)
	_expect(second.prevented, "dead target: hit not prevented")
	_expect(is_zero_approx(second.actual_damage), "dead target: damage applied")


func _test_prevented_hits() -> void:
	var hero_a := _make_state(3, 100.0, CombatTypes.Faction.HERO)
	var hero_b := _make_state(4, 100.0, CombatTypes.Faction.HERO)
	var enemy_a := _make_state(5, 100.0, CombatTypes.Faction.ENEMY)
	var enemy_b := _make_state(6, 100.0, CombatTypes.Faction.ENEMY)
	var attack := _make_attack(10.0)
	var result := DamageResult.new()
	_system.deal(attack, hero_a, hero_b, result)
	_expect(result.prevented, "friendly fire: hero to hero not prevented")
	_system.deal(attack, hero_a, hero_a, result)
	_expect(result.prevented, "self damage not prevented")
	_system.deal(attack, enemy_a, enemy_b, result)
	_expect(result.prevented, "friendly fire: enemy to enemy not prevented")
	hero_b.invulnerable_ticks = 10
	_system.deal(attack, enemy_a, hero_b, result)
	_expect(result.prevented, "i-frames: hit not prevented")
	_expect(is_equal_approx(hero_b.hp, 100.0), "prevented hits changed hp")


func _test_iframes_expire() -> void:
	var hero := _make_state(7, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(8, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(5.0)
	var result := DamageResult.new()
	hero.invulnerable_ticks = 30
	_tick(hero, 29)
	_system.deal(attack, enemy, hero, result)
	_expect(result.prevented, "i-frames: hit landed before 0.5 s elapsed")
	_tick(hero, 1)
	_system.deal(attack, enemy, hero, result)
	_expect(not result.prevented, "i-frames: hit still prevented after 0.5 s")
	_expect(is_equal_approx(result.actual_damage, 5.0),
		"i-frames: actual %s, expected 5" % result.actual_damage)


func _test_poise_stagger() -> void:
	var hero := _make_state(9, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(10, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(1.0, 100.0)
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_expect(result.staggered, "stagger: not triggered at 0 poise")
	_expect(enemy.statuses.has(CombatTypes.Status.STUN), "stagger: stun not applied")
	_expect(is_equal_approx(enemy.poise, 100.0),
		"stagger: poise %s, expected full restore" % enemy.poise)
	_expect(not enemy.can_act(), "stagger: can act during stagger")
	_tick(enemy, 24)
	_expect(not enemy.statuses.has(CombatTypes.Status.STUN), "stagger: stun longer than 0.4 s")
	_expect(enemy.can_act(), "stagger: cannot act after recovery")


func _test_poise_regen() -> void:
	var hero := _make_state(11, 1000.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(12, 1000.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(0.0, 40.0)
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_expect(result.staggered == false, "regen: 40 poise damage staggered")
	_expect(is_equal_approx(enemy.poise, 60.0), "regen: poise %s, expected 60" % enemy.poise)
	_tick(enemy, 47)
	_expect(is_equal_approx(enemy.poise, 60.0),
		"regen: poise %s before 0.8 s, expected 60" % enemy.poise)
	_tick(enemy, 1)
	_expect(is_equal_approx(enemy.poise, 60.0 + 50.0 / TICKS),
		"regen: poise %s at 0.8 s, expected first regen tick" % enemy.poise)
	_tick(enemy, 35)
	_expect(is_equal_approx(enemy.poise, 90.0),
		"regen: poise %s after 0.6 s of regen, expected 90" % enemy.poise)


func _test_hitstop() -> void:
	var hero := _make_state(13, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(14, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(5.0)
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_expect(enemy.hitstop_ticks == 2, "hitstop: %s ticks, expected 2" % enemy.hitstop_ticks)
	_expect(not enemy.can_act(), "hitstop: can act during hitstop")
	_expect(is_equal_approx(enemy.movement_multiplier(), 0.0),
		"hitstop: movement multiplier %s" % enemy.movement_multiplier())
	_tick(enemy, 2)
	_expect(enemy.can_act(), "hitstop: cannot act after 2 ticks")
	_expect(is_equal_approx(enemy.movement_multiplier(), 1.0),
		"hitstop: movement multiplier %s after expiry" % enemy.movement_multiplier())


func _test_status_applications_on_hit() -> void:
	var hero := _make_state(15, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(16, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(5.0)
	var burn := StatusApplication.new()
	burn.status = CombatTypes.Status.BURN
	burn.stacks = 2
	attack.status_applications = [burn]
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_expect(enemy.statuses.stacks_of(CombatTypes.Status.BURN) == 2,
		"on-hit: burn stacks %s, expected 2" % enemy.statuses.stacks_of(CombatTypes.Status.BURN))
	_expect(enemy.statuses.source_ids[CombatTypes.Status.BURN] == hero.actor_id,
		"on-hit: burn source %s, expected %s" % [enemy.statuses.source_ids[CombatTypes.Status.BURN], hero.actor_id])
	var zero_attack := _make_attack(0.0)
	var poison := StatusApplication.new()
	poison.status = CombatTypes.Status.POISON
	poison.stacks = 1
	zero_attack.status_applications = [poison]
	_system.deal(zero_attack, hero, enemy, result)
	_expect(enemy.statuses.stacks_of(CombatTypes.Status.POISON) == 1,
		"on-hit zero damage: poison stacks %s, expected 1" % enemy.statuses.stacks_of(CombatTypes.Status.POISON))
	var prevented_attack := _make_attack(5.0)
	enemy.invulnerable_ticks = 10
	var blocked := DamageResult.new()
	_system.deal(prevented_attack, hero, enemy, blocked)
	_expect(blocked.prevented, "on-hit i-frames: hit not prevented")
	_expect(enemy.statuses.stacks_of(CombatTypes.Status.BURN) == 2,
		"on-hit i-frames: burn stacks changed")


func _test_after_damage_notifications() -> void:
	var hero := _make_state(17, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(18, 10.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var source_recorder := _attach_recorder(hero)
	var target_recorder := _attach_recorder(enemy)
	var attack := _make_attack(20.0)
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_expect(source_recorder.calls.size() == 1 and is_equal_approx(source_recorder.calls[0], 10.0),
		"notify: source recorder %s, expected [10]" % [source_recorder.calls])
	_expect(target_recorder.calls.size() == 1 and is_equal_approx(target_recorder.calls[0], 10.0),
		"notify: target recorder %s, expected [10]" % [target_recorder.calls])
	var zero_attack := _make_attack(0.0)
	_system.deal(zero_attack, hero, enemy, result)
	_expect(source_recorder.calls.size() == 1 and target_recorder.calls.size() == 1,
		"notify: zero-damage hit fired notifications")


func _test_bleed_incoming() -> void:
	var hero := _make_state(19, 1000.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(20, 1000.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var bleeding_attack := _make_attack(0.0)
	var bleed := StatusApplication.new()
	bleed.status = CombatTypes.Status.BLEED
	bleed.stacks = 4
	bleeding_attack.status_applications = [bleed]
	var result := DamageResult.new()
	_system.deal(bleeding_attack, hero, enemy, result)
	_expect(enemy.statuses.stacks_of(CombatTypes.Status.BLEED) == 4,
		"bleed: stacks %s, expected 4" % enemy.statuses.stacks_of(CombatTypes.Status.BLEED))
	var attack := _make_attack(10.0)
	_system.deal(attack, hero, enemy, result)
	_expect(is_equal_approx(result.damage, 12.0),
		"bleed: damage %s, expected 12 (+20%%)" % result.damage)
	_system.deal(attack, hero, enemy, result)
	_expect(is_equal_approx(result.damage, 12.0),
		"bleed: stacks consumed, second hit %s, expected 12" % result.damage)


func _test_dot_kill_and_source() -> void:
	var hero := _make_state(21, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(22, 3.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var source_recorder := _attach_recorder(hero)
	var attack := _make_attack(0.0)
	var burn := StatusApplication.new()
	burn.status = CombatTypes.Status.BURN
	burn.stacks = 1
	attack.status_applications = [burn]
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_tick(enemy, 45)
	_expect(not enemy.alive, "dot kill: enemy alive after 3 burn ticks")
	_expect(is_zero_approx(enemy.hp), "dot kill: hp %s, expected 0" % enemy.hp)
	_expect(not enemy.statuses.has(CombatTypes.Status.BURN), "dot kill: statuses not cleared")
	var calls_after_death := source_recorder.calls.size()
	_tick(enemy, 60)
	_expect(source_recorder.calls.size() == calls_after_death,
		"dot kill: damage kept landing after death")
	_expect(is_zero_approx(enemy.hp), "dot kill: hp changed after death")


func _test_dot_source_resolution() -> void:
	var hero := _make_state(23, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(24, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	# Unregistered source id falls back to a sourceless request and still ticks.
	enemy.statuses.apply(CombatTypes.Status.BURN, 1, 999)
	_tick(enemy, 15)
	_expect(is_equal_approx(enemy.hp, 98.75),
		"dot source: hp %s, expected 98.75" % enemy.hp)
	# Same-faction registered source is friendly fire and gets prevented.
	hero.statuses.apply(CombatTypes.Status.BURN, 1, hero.actor_id)
	_tick(hero, 15)
	_expect(is_equal_approx(hero.hp, 100.0),
		"dot friendly fire: hero hp %s, expected 100" % hero.hp)


func _test_heal_and_health_ratio() -> void:
	var hero := _make_state(25, 10.0, CombatTypes.Faction.HERO)
	hero.hp = 5.0
	_expect(is_equal_approx(hero.health_ratio(), 0.5),
		"health ratio: %s, expected 0.5" % hero.health_ratio())
	hero.heal(20.0)
	_expect(is_equal_approx(hero.hp, 10.0), "heal: hp %s, expected cap 10" % hero.hp)


func _test_reconfigure_resets_state() -> void:
	var definition := CombatantDefinition.new()
	definition.max_hp = 100.0
	definition.max_poise = 100.0
	var state := CombatantState.new()
	state.configure(definition, 40, CombatTypes.Faction.ENEMY, StatusConfig.new(), TICKS)
	var old_modifier := ModifierDefinition.new()
	old_modifier.id = &"old_modifier"
	old_modifier.duration = 10.0
	state.modifiers.add(old_modifier, 7)
	state.statuses.apply(CombatTypes.Status.BURN, 2, 7)
	state.hp = 10.0
	state.invulnerable_ticks = 5
	state.hitstop_ticks = 2
	state.knockback_ticks = 3
	state.knockback_per_tick = Vector2.RIGHT
	state.configure(definition, 41, CombatTypes.Faction.HERO, StatusConfig.new(), TICKS)
	_expect(state.modifiers.instances.is_empty(), "reconfigure: old modifiers kept")
	_expect(not state.statuses.has(CombatTypes.Status.BURN), "reconfigure: old statuses kept")
	_expect(state.statuses.source_ids[CombatTypes.Status.BURN] == -1,
		"reconfigure: old status source id %s, expected -1" % state.statuses.source_ids[CombatTypes.Status.BURN])
	_expect(state.actor_id == 41, "reconfigure: actor id %s, expected 41" % state.actor_id)
	_expect(state.faction == CombatTypes.Faction.HERO, "reconfigure: faction not updated")
	_expect(is_equal_approx(state.hp, 100.0), "reconfigure: hp %s, expected full" % state.hp)
	_expect(is_equal_approx(state.modifiers.stats.max_hp, 100.0),
		"reconfigure: max hp %s, expected 100" % state.modifiers.stats.max_hp)
	_expect(state.invulnerable_ticks == 0, "reconfigure: i-frames kept")
	_expect(state.hitstop_ticks == 0, "reconfigure: hitstop kept")
	_expect(state.knockback_ticks == 0, "reconfigure: knockback kept")
	_expect(state.knockback_per_tick == Vector2.ZERO,
		"reconfigure: knockback per tick %s, expected zero" % state.knockback_per_tick)
	# Old DoT cadence is gone: a fresh burn from an enemy source takes a full
	# interval to tick on the reconfigured hero.
	var enemy_source := _make_state(42, 100.0, CombatTypes.Faction.ENEMY)
	_register(enemy_source)
	_register(state)
	state.statuses.apply(CombatTypes.Status.BURN, 1, enemy_source.actor_id)
	_tick(state, 14)
	_expect(is_equal_approx(state.hp, 100.0),
		"reconfigure: stale DoT cadence ticked early, hp %s" % state.hp)
	_tick(state, 1)
	_expect(is_equal_approx(state.hp, 98.75),
		"reconfigure: fresh burn damage %s, expected 1.25 after a full interval" % [100.0 - state.hp])


func _test_dot_no_hitstop_and_no_bleed_amp() -> void:
	var hero := _make_state(43, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(44, 1000.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	enemy.statuses.apply(CombatTypes.Status.BURN, 1, hero.actor_id)
	_tick(enemy, 15)
	_expect(is_equal_approx(enemy.hp, 998.75), "dot: hp %s, expected 998.75" % enemy.hp)
	_expect(enemy.hitstop_ticks == 0, "dot: hitstop %s ticks, expected 0" % enemy.hitstop_ticks)
	# Bleed amplifies direct hits but not DoT pulses.
	enemy.statuses.apply(CombatTypes.Status.BLEED, 4, hero.actor_id)
	_tick(enemy, 15)
	_expect(is_equal_approx(1000.0 - enemy.hp, 2.5),
		"dot vs bleed: hp delta %s, expected 2.5 (unamplified)" % [1000.0 - enemy.hp])
	_expect(enemy.hitstop_ticks == 0, "dot vs bleed: hitstop %s, expected 0" % enemy.hitstop_ticks)
	var attack := _make_attack(10.0)
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_expect(is_equal_approx(result.damage, 12.0),
		"bleed: hit damage %s, expected 12 (+20%%)" % result.damage)
	_expect(enemy.hitstop_ticks == 2, "bleed: hitstop %s, expected 2" % enemy.hitstop_ticks)


func _test_queued_secondary_damage() -> void:
	var hero := _make_state(45, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(46, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var retaliation := _make_attack(3.0)
	var handler := RetaliationHandler.new()
	_handlers.append(handler)
	handler.system = _system
	handler.attack = retaliation
	var definition := ModifierDefinition.new()
	definition.id = &"retaliation"
	definition.duration = 0.0
	definition.after_damage_handler = handler
	enemy.modifiers.add(definition)
	var attack := _make_attack(5.0)
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result)
	_expect(is_equal_approx(hero.hp, 100.0),
		"queue: retaliation landed before flush, hero hp %s" % hero.hp)
	var processed := _system.flush()
	_expect(processed == 1, "queue: flush processed %s, expected 1" % processed)
	_expect(is_equal_approx(hero.hp, 97.0), "queue: hero hp %s, expected 97" % hero.hp)
	_expect(hero.hitstop_ticks == 2,
		"queue: secondary hitstop %s ticks, expected 2" % hero.hitstop_ticks)
	_expect(_system.flush() == 0, "queue: second flush not empty")


func _test_bounded_queue_from_handler_deal() -> void:
	var hero := _make_state(47, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(48, 100000.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var self_attack := _make_attack(1.0)
	var handler := SelfQueueHandler.new()
	_handlers.append(handler)
	handler.system = _system
	handler.attack = self_attack
	var definition := ModifierDefinition.new()
	definition.id = &"self_queue"
	definition.duration = 0.0
	definition.after_damage_handler = handler
	enemy.modifiers.add(definition)
	# queue_hit enforces its explicit cap and reports overflow.
	_expect(_system.queue_hit(self_attack, hero, enemy), "queue cap: first enqueue rejected")
	for i: int in DamageSystem.MAX_QUEUED_HITS:
		_system.queue_hit(self_attack, hero, enemy)
	_expect(not _system.queue_hit(self_attack, hero, enemy),
		"queue cap: enqueue beyond %d accepted" % DamageSystem.MAX_QUEUED_HITS)
	var hp_before := enemy.hp
	# Each processed hit re-queues via the handler's direct deal(); a single flush
	# must stay bounded and terminate.
	var processed := _system.flush()
	_expect(processed == DamageSystem.MAX_QUEUED_HITS,
		"queue cap: flush processed %s, expected %d" % [processed, DamageSystem.MAX_QUEUED_HITS])
	_expect(is_equal_approx(hp_before - enemy.hp, float(DamageSystem.MAX_QUEUED_HITS)),
		"queue cap: damage %s, expected %d" % [hp_before - enemy.hp, DamageSystem.MAX_QUEUED_HITS])
	var second := _system.flush()
	_expect(second == DamageSystem.MAX_QUEUED_HITS,
		"queue cap: second flush %s, expected bounded refill" % second)


func _test_knockback_distance_and_decay() -> void:
	var hero := _make_state(49, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(50, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(5.0)
	attack.knockback_distance = 1.2
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result, 1.0, Vector2(0, 30))
	var expected_ticks := maxi(1, roundi(CombatantState.KNOCKBACK_DURATION_SECONDS * TICKS))
	_expect(enemy.knockback_ticks == expected_ticks,
		"knockback: ticks %s, expected %s" % [enemy.knockback_ticks, expected_ticks])
	var offset := enemy.knockback_offset()
	_expect(is_zero_approx(offset.x), "knockback: x %s, expected 0" % offset.x)
	_expect(is_equal_approx(offset.y, 1.2 / expected_ticks),
		"knockback: per-tick y %s, expected %s" % [offset.y, 1.2 / expected_ticks])
	_expect(is_equal_approx(offset.length(), 1.2 / expected_ticks),
		"knockback: per-tick length %s, expected full distance over duration" % offset.length())
	_tick(enemy, expected_ticks)
	_expect(enemy.knockback_ticks == 0, "knockback: ticks left after duration")
	_expect(enemy.knockback_offset() == Vector2.ZERO,
		"knockback: offset %s after duration, expected zero" % enemy.knockback_offset())


func _test_knockback_requires_distance_and_direction() -> void:
	var hero := _make_state(51, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(52, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var no_distance := _make_attack(5.0)
	var result := DamageResult.new()
	_system.deal(no_distance, hero, enemy, result, 1.0, Vector2.RIGHT)
	_expect(enemy.knockback_ticks == 0, "knockback: applied without knockback_distance")
	var no_direction := _make_attack(5.0)
	no_direction.knockback_distance = 1.0
	_system.deal(no_direction, hero, enemy, result, 1.0)
	_expect(enemy.knockback_ticks == 0, "knockback: applied without a direction")
	# Direct CombatantState call: dead-target and zero-input guards.
	enemy.apply_knockback(1.0, Vector2.RIGHT)
	_expect(enemy.knockback_ticks > 0, "knockback: direct apply_knockback ignored")
	enemy.alive = false
	enemy.knockback_ticks = 0
	enemy.apply_knockback(1.0, Vector2.RIGHT)
	_expect(enemy.knockback_ticks == 0, "knockback: applied to a dead combatant")
	enemy.alive = true


func _test_knockback_prevented_and_dot() -> void:
	var hero := _make_state(53, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(54, 100.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(5.0)
	attack.knockback_distance = 1.0
	enemy.invulnerable_ticks = 10
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result, 1.0, Vector2.RIGHT)
	_expect(result.prevented, "knockback prevented: hit not prevented")
	_expect(enemy.knockback_ticks == 0, "knockback: applied on a prevented hit")
	enemy.invulnerable_ticks = 0
	# A DoT-tagged attack with a knockback distance must not push either.
	var dot_attack := _make_attack(5.0)
	dot_attack.tags = CombatTypes.AttackTag.DOT
	dot_attack.knockback_distance = 1.0
	_system.deal(dot_attack, hero, enemy, result, 1.0, Vector2.RIGHT)
	_expect(enemy.knockback_ticks == 0, "knockback: applied on a DoT-tagged hit")
	# Status DoT pulses never carry a knockback direction or distance.
	enemy.statuses.apply(CombatTypes.Status.BURN, 1, hero.actor_id)
	_tick(enemy, 15)
	_expect(enemy.knockback_ticks == 0, "knockback: applied by a DoT pulse")


func _test_knockback_not_applied_to_dead() -> void:
	var hero := _make_state(55, 100.0, CombatTypes.Faction.HERO)
	var enemy := _make_state(56, 5.0, CombatTypes.Faction.ENEMY)
	_register(hero)
	_register(enemy)
	var attack := _make_attack(20.0)
	attack.knockback_distance = 1.0
	var result := DamageResult.new()
	_system.deal(attack, hero, enemy, result, 1.0, Vector2.RIGHT)
	_expect(result.target_died, "knockback death: target not dead")
	_expect(enemy.knockback_ticks == 0,
		"knockback: applied on a killing blow, ticks %s" % enemy.knockback_ticks)


func _register(state: CombatantState) -> void:
	_system.register_combatant(state)
	_registered.append(state)


## Test handlers hold the system while the system holds registered combatants;
## break those cycles and drop the registry so nothing survives SceneTree teardown.
func _cleanup() -> void:
	for handler: Variant in _handlers:
		handler.system = null
	for state: CombatantState in _registered:
		_system.unregister_combatant(state.actor_id)


func _make_state(id: int, hp: float, faction: CombatTypes.Faction) -> CombatantState:
	var definition := CombatantDefinition.new()
	definition.max_hp = hp
	definition.max_poise = 100.0
	var state := CombatantState.new()
	state.configure(definition, id, faction, StatusConfig.new(), TICKS)
	return state


func _make_attack(base_damage: float, poise_damage := 0.0) -> AttackDefinition:
	var attack := AttackDefinition.new()
	attack.id = &"test_attack"
	attack.damage_type = CombatTypes.DamageType.PHYSICAL
	attack.base_damage = base_damage
	attack.poise_damage = poise_damage
	attack.tags = CombatTypes.AttackTag.MELEE
	return attack


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
