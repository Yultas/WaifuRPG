extends SceneTree
## Fixed-tick tests of PartyController (data/heroes/party_default.tres): exactly 3
## heroes, pocket ticking of HP/cooldowns, swap cooldown (1 s), swap to a dead hero
## refused, D-pad style next/prev cycling that skips dead heroes, swap during a dash
## allowed (the dash keeps running — and moving — in the pocket, so its remaining
## distance survives until the hero returns) and swap during an unfinished skill
## cancels the skill without consuming its cooldown.
## Run: godot --headless --path . -s res://tests/test_party_controller.gd

const PARTY_TRES := "res://data/heroes/party_default.tres"

var _failures := 0
var _status_config: StatusConfig
var _damage_system: DamageSystem
var _party: PartyController
var _enemy_state: CombatantState
var _enemy_attack: AttackDefinition
var _skill_fires := 0
var _activated: Array[int] = []
var _deactivated: Array[int] = []


func _initialize() -> void:
	_test_party_has_exactly_three_heroes()
	_test_input_frame_commands()
	_test_swap_cooldown_and_signals()
	_test_swap_to_dead_refused()
	_test_swap_next_prev_skip_dead()
	_test_swap_during_dash_continues_it()
	_test_swap_cancels_unfinished_skill()
	_test_pocket_cooldowns_tick_hp_stays()
	_test_dash_refused_during_skill()
	_test_party_wipe()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_party_has_exactly_three_heroes() -> void:
	_setup()
	_expect(_party.states.size() == PartyController.PARTY_SIZE,
		"party: %d heroes" % _party.states.size())
	_expect(_party.controllers.size() == PartyController.PARTY_SIZE,
		"party: %d controllers" % _party.controllers.size())
	_expect(_party.active_index() == 0, "party: active index is %s" % _party.active_index())
	for hero_state: HeroCombatState in _party.states:
		_expect(hero_state.alive and is_equal_approx(hero_state.hp, 10.0),
			"party: hero hp %s alive %s" % [hero_state.hp, hero_state.alive])
	_expect(_party.party_alive(), "party: party_alive is false on full party")


func _test_input_frame_commands() -> void:
	_setup()
	var attack_frame := HeroInputFrame.new()
	attack_frame.sequence = 7
	attack_frame.move = Vector2.RIGHT
	attack_frame.press(HeroInputFrame.Action.ATTACK)
	_party.apply_input(attack_frame)
	_expect(_party.active_controller().move_intent == Vector2.RIGHT,
		"input-frame: move intent was not applied")
	_expect(_party.active_state().action == HeroCombatState.Action.ATTACKING,
		"input-frame: attack was not requested")
	_expect(_party.active_controller().position == Vector2.ZERO,
		"input-frame: applying input unexpectedly advanced the tick")
	var swap_frame := HeroInputFrame.new()
	swap_frame.press(HeroInputFrame.Action.SWAP_2)
	_party.apply_input(swap_frame)
	_expect(_party.active_index() == 1, "input-frame: swap was not requested")
	_expect(_party.active_controller().move_intent == Vector2.ZERO,
		"input-frame: next frame did not replace move intent")


func _test_swap_cooldown_and_signals() -> void:
	_setup()
	_expect(_party.request_swap_to(1), "swap: first swap rejected")
	_expect(_party.active_index() == 1, "swap: active is %s" % _party.active_index())
	_expect(not _party.request_swap_to(2), "swap: second swap during cooldown accepted")
	_party.tick()
	_expect(not _party.request_swap_to(1), "swap: swap to self accepted")
	_tick(58) ## 59 ticks since the swap: one tick of cooldown still left.
	_expect(not _party.request_swap_to(2), "swap: swap 1 tick before cooldown end accepted")
	_tick(1)
	_expect(_party.request_swap_to(2), "swap: swap after 1 s cooldown rejected")
	_expect(_party.active_index() == 2, "swap: active is %s" % _party.active_index())
	_expect(_activated == [1, 2], "swap: activated %s" % [_activated])
	_expect(_deactivated == [0, 1], "swap: deactivated %s" % [_deactivated])


func _test_swap_to_dead_refused() -> void:
	_setup()
	_kill_hero(1)
	_expect(not _party.request_swap_to(1), "dead: swap to dead hero accepted")
	_expect(_party.active_index() == 0, "dead: active changed to %s" % _party.active_index())


func _test_swap_next_prev_skip_dead() -> void:
	_setup()
	_kill_hero(1)
	_expect(_party.request_swap_next(), "cycle: next rejected with alive targets")
	_expect(_party.active_index() == 2, "cycle: next landed on dead hero 1" )
	_tick(60)
	_expect(_party.request_swap_prev(), "cycle: prev rejected with alive targets")
	_expect(_party.active_index() == 0, "cycle: prev did not skip dead hero 1")
	_kill_hero(2)
	_expect(not _party.request_swap_next(), "cycle: next accepted with no alive target")
	_expect(_party.active_index() == 0, "cycle: active changed with no alive target")


func _test_swap_during_dash_continues_it() -> void:
	_setup()
	_party.set_move_intent(Vector2.RIGHT)
	_expect(_party.request_dash(), "dash-swap: dash rejected")
	_expect(_party.states[0].action == HeroCombatState.Action.DASHING, "dash-swap: not dashing")
	_tick(5)
	var dashed_x := 5.0 * 3.0 / 11.0
	_expect(is_equal_approx(_party.controllers[0].position.x, dashed_x),
		"dash-swap: active dash moved to %s" % _party.controllers[0].position.x)
	_expect(_party.request_swap_to(1), "dash-swap: swap during dash rejected")
	_expect(_party.states[0].action == HeroCombatState.Action.DASHING,
		"dash-swap: dash cancelled, action is %s" % _party.states[0].action)
	_tick(1) ## The dash keeps ticking and moving in the pocket: 6 -> 5 ticks left.
	_expect(_party.states[0].action_ticks_left == 5,
		"dash-swap: dash ticks left %s, expected 5 (runs in pocket)" \
		% _party.states[0].action_ticks_left)
	_expect(is_equal_approx(_party.controllers[0].position.x, 6.0 * 3.0 / 11.0),
		"dash-swap: pocket dash moved to %s" % _party.controllers[0].position.x)
	var result := _hit_hero(0, 5.0)
	_expect(result.prevented, "dash-swap: hit during pocket i-frames not prevented")
	_tick(5)
	_expect(_party.states[0].action == HeroCombatState.Action.IDLE,
		"dash-swap: dash did not finish in pocket")
	_expect(_party.states[0].dash_cooldown_left == 37,
		"dash-swap: dash cooldown %s, expected 37" % _party.states[0].dash_cooldown_left)
	# The remaining dash distance was really applied in the pocket, not dropped.
	_expect(is_equal_approx(_party.controllers[0].position.x, 3.0),
		"dash-swap: dash distance lost, x is %s, expected 3 m" \
		% _party.controllers[0].position.x)
	# Swap back after the cooldown: the dashed position is kept and stays put
	# (move intent was zeroed) — the dash does not resume or double-apply.
	_tick(60)
	_expect(_party.request_swap_to(0), "dash-swap: swap back rejected")
	_party.set_move_intent(Vector2.ZERO)
	_expect(is_equal_approx(_party.controllers[0].position.x, 3.0),
		"dash-swap: position after return is %s, expected 3 m" \
		% _party.controllers[0].position.x)
	_tick(5)
	_expect(is_equal_approx(_party.controllers[0].position.x, 3.0),
		"dash-swap: hero drifted to %s after return without input" \
		% _party.controllers[0].position.x)


func _test_swap_cancels_unfinished_skill() -> void:
	_setup()
	_expect(_party.request_skill(), "skill-swap: skill rejected")
	_expect(_party.states[0].action == HeroCombatState.Action.SKILLING, "skill-swap: not casting")
	_expect(_party.request_swap_to(1), "skill-swap: swap during skill rejected")
	_expect(_party.states[0].action == HeroCombatState.Action.IDLE,
		"skill-swap: skill not cancelled, action is %s" % _party.states[0].action)
	_tick(30)
	_expect(_skill_fires == 0, "skill-swap: cancelled skill fired %d times" % _skill_fires)
	_expect(_party.states[0].skill_cooldown_left == 0,
		"skill-swap: cancelled skill consumed cooldown (%s ticks)" \
		% _party.states[0].skill_cooldown_left)


func _test_pocket_cooldowns_tick_hp_stays() -> void:
	_setup()
	_expect(_party.request_swap_to(1), "pocket: swap rejected")
	_tick(60) ## Burn the swap cooldown.
	_expect(_party.request_skill(), "pocket: skill on hero 2 rejected")
	_tick(18)
	_expect(_skill_fires == 1, "pocket: skill fired %d times" % _skill_fires)
	_expect(_party.request_swap_to(2), "pocket: second swap rejected")
	_tick(60)
	_expect(_party.states[1].skill_cooldown_left == 120,
		"pocket: hero 2 skill cooldown %s, expected 120 after 1 s in pocket" \
		% _party.states[1].skill_cooldown_left)
	_expect(is_equal_approx(_party.states[0].hp, 10.0),
		"pocket: pocket hero hp changed to %s" % _party.states[0].hp)


func _test_dash_refused_during_skill() -> void:
	_setup()
	_expect(_party.request_skill(), "skill-dash: skill rejected")
	_expect(not _party.request_dash(), "skill-dash: dash during skill accepted")


func _test_party_wipe() -> void:
	_setup()
	_kill_hero(0)
	_kill_hero(1)
	_kill_hero(2)
	_expect(not _party.party_alive(), "wipe: party_alive is true on wiped party")
	_expect(not _party.request_swap_next(), "wipe: next accepted on wiped party")
	_expect(not _party.request_swap_to(1), "wipe: swap accepted on wiped party")


func _setup() -> void:
	_status_config = StatusConfig.new()
	_damage_system = DamageSystem.new()
	_damage_system.status_config = _status_config
	_party = PartyController.new()
	_party.setup(load(PARTY_TRES), _damage_system, _status_config)
	for controller: HeroActionController in _party.controllers:
		controller.skill_fired.connect(_on_skill_fired)
	_party.hero_activated.connect(func(index: int) -> void: _activated.append(index))
	_party.hero_deactivated.connect(func(index: int) -> void: _deactivated.append(index))
	var enemy_definition := CombatantDefinition.new()
	enemy_definition.max_hp = 10000.0
	enemy_definition.max_poise = 10000.0
	_enemy_state = CombatantState.new()
	_enemy_state.configure(enemy_definition, 99, CombatTypes.Faction.ENEMY, _status_config)
	_enemy_attack = AttackDefinition.new()
	_enemy_attack.id = &"enemy_hit"
	_enemy_attack.base_damage = 0.0
	_skill_fires = 0
	_activated.clear()
	_deactivated.clear()


func _on_skill_fired(_attack: AttackDefinition, _origin: Vector2, _direction: Vector2) -> void:
	_skill_fires += 1


func _kill_hero(index: int) -> void:
	var result := _hit_hero(index, 20.0)
	_expect(result.target_died, "kill: hero %d did not die" % index)


func _hit_hero(index: int, damage: float) -> DamageResult:
	_enemy_attack.base_damage = damage
	var result := DamageResult.new()
	_damage_system.deal(_enemy_attack, _enemy_state, _party.states[index], result)
	return result


func _tick(count: int) -> void:
	for _i: int in count:
		_party.tick()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
