extends SceneTree
## Fixed-tick tests of HeroCombatState + HeroActionController driven by the
## docs/gdd/03_combat.md prototype values (data/heroes/hero_default.tres):
## manual attack (20 physical, 0.35 s recovery, no autoattack), skill (40 magical,
## 3 s cooldown), dash (3 m / 0.18 s, full i-frames, 0.8 s cooldown), movement,
## death and the programmatic InputMap registration. Knockback priority: forced
## displacement overrides intent movement, never a running dash (i-frames block
## new knockbacks mid-dash), and it carries pocket heroes like the pocket dash.
## Run: godot --headless --path . -s res://tests/test_hero_combat.gd

const HERO_TRES := "res://data/heroes/hero_default.tres"

var _failures := 0
var _status_config: StatusConfig
var _damage_system: DamageSystem
var _hero_state: HeroCombatState
var _controller: HeroActionController
var _enemy_state: CombatantState
var _enemy_attack: AttackDefinition
var _attack_hits: Array[DamageResult] = []
var _skill_hits: Array[DamageResult] = []


func _initialize() -> void:
	_test_manual_attack_with_recovery()
	_test_no_autoattack()
	_test_movement_speed_and_facing()
	_test_skill_cast_and_cooldown()
	_test_dash_distance_iframes_cooldown()
	_test_dash_uses_facing_without_input()
	_test_dash_respects_external_iframes()
	_test_dash_cancels_attack_recovery()
	_test_death()
	_test_knockback_overrides_intent_and_expires()
	_test_knockback_blocked_by_dash_iframes()
	_test_knockback_stacks_with_dash()
	_test_knockback_displaces_pocket_hero()
	_test_input_map_registration()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_manual_attack_with_recovery() -> void:
	_setup()
	_expect(_controller.request_attack(), "attack: first press rejected")
	_expect(_attack_hits.size() == 1, "attack: got %d hits" % _attack_hits.size())
	if _attack_hits.size() == 1:
		_expect(is_equal_approx(_attack_hits[0].damage, 20.0),
			"attack: damage %s, expected 20" % _attack_hits[0].damage)
		_expect(_attack_hits[0].damage_type == CombatTypes.DamageType.PHYSICAL,
			"attack: type %s, expected PHYSICAL" % _attack_hits[0].damage_type)
	_expect(not _controller.request_attack(), "attack: second press during recovery accepted")
	_expect(_attack_hits.size() == 1, "attack: extra hit during recovery")
	# Recovery 0.35 s = 21 ticks; after 20 ticks the next press is still gated.
	_tick(20)
	_expect(not _controller.request_attack(), "attack: press 1 tick before recovery end accepted")
	_tick(1)
	_expect(_controller.request_attack(), "attack: press after recovery rejected")
	_expect(_attack_hits.size() == 2, "attack: got %d hits after recovery" % _attack_hits.size())


func _test_no_autoattack() -> void:
	_setup()
	_controller.move_intent = Vector2.RIGHT
	_tick(120)
	_expect(_attack_hits.is_empty(), "autoattack: %d hits without presses" % _attack_hits.size())
	_expect(_controller.position.is_equal_approx(Vector2(10.0, 0.0)),
		"autoattack: position %s, expected (10, 0) after 2 s" % _controller.position)


func _test_movement_speed_and_facing() -> void:
	_setup()
	_controller.move_intent = Vector2.RIGHT
	_tick(60)
	_expect(_controller.position.is_equal_approx(Vector2(5.0, 0.0)),
		"move: position %s, expected (5, 0) after 1 s" % _controller.position)
	_expect(_controller.facing.is_equal_approx(Vector2.RIGHT), "move: facing is %s" % _controller.facing)
	_tick(60)
	_expect(_controller.position.is_equal_approx(Vector2(10.0, 0.0)),
		"move: position %s, expected (10, 0) after 2 s" % _controller.position)


func _test_skill_cast_and_cooldown() -> void:
	_setup()
	_expect(_controller.request_skill(), "skill: first press rejected")
	_expect(not _controller.request_skill(), "skill: press during cast accepted")
	_tick(17)
	_expect(_skill_hits.is_empty(), "skill: fired %s s early" % "0.28")
	_tick(1)
	_expect(_skill_hits.size() == 1, "skill: got %d fires after 0.3 s cast" % _skill_hits.size())
	if _skill_hits.size() == 1:
		_expect(is_equal_approx(_skill_hits[0].damage, 40.0),
			"skill: damage %s, expected 40" % _skill_hits[0].damage)
		_expect(_skill_hits[0].damage_type == CombatTypes.DamageType.MAGICAL,
			"skill: type %s, expected MAGICAL" % _skill_hits[0].damage_type)
	# Cooldown 3 s = 180 ticks, starting on the fire tick.
	_expect(not _controller.request_skill(), "skill: press during cooldown accepted")
	_tick(179)
	_expect(not _controller.request_skill(), "skill: press 1 tick before cooldown end accepted")
	_tick(1)
	_expect(_controller.request_skill(), "skill: press after cooldown rejected")
	_expect(_skill_hits.size() == 1, "skill: fired again during cast")


func _test_dash_distance_iframes_cooldown() -> void:
	_setup()
	_controller.move_intent = Vector2.RIGHT
	_expect(_controller.request_dash(), "dash: first press rejected")
	_tick(5)
	var mid_dash_x := 5.0 * 3.0 / 11.0
	_expect(is_equal_approx(_controller.position.x, mid_dash_x),
		"dash: x %s, expected %s mid-dash" % [_controller.position.x, mid_dash_x])
	_expect(_hero_state.action == HeroCombatState.Action.DASHING, "dash: not dashing mid-dash")
	var result := _hit_hero(5.0)
	_expect(result.prevented, "dash: hit during i-frames was not prevented")
	_expect(is_equal_approx(_hero_state.hp, 10.0), "dash: hp %s after prevented hit" % _hero_state.hp)
	_tick(6)
	_expect(_hero_state.action == HeroCombatState.Action.IDLE, "dash: still dashing after 0.18 s")
	_expect(is_equal_approx(_controller.position.x, 3.0),
		"dash: x %s, expected 3 m total" % _controller.position.x)
	result = _hit_hero(5.0)
	_expect(not result.prevented and is_equal_approx(_hero_state.hp, 5.0),
		"dash: hit after dash prevented=%s, hp %s" % [result.prevented, _hero_state.hp])
	# Cooldown 0.8 s = 48 ticks; 11 dash ticks already elapsed.
	_expect(not _controller.request_dash(), "dash: press during cooldown accepted")
	_tick(37)
	_expect(_controller.request_dash(), "dash: press after cooldown rejected")


func _test_dash_uses_facing_without_input() -> void:
	_setup()
	_expect(_controller.request_dash(), "dash(facing): press rejected")
	_tick(11)
	_expect(_controller.position.is_equal_approx(Vector2(0.0, 3.0)),
		"dash(facing): position %s, expected (0, 3) along default facing DOWN" % _controller.position)


func _test_dash_respects_external_iframes() -> void:
	_setup()
	_hero_state.invulnerable_ticks = 30
	_expect(_controller.request_dash(), "dash-iframe: dash rejected")
	_expect(_hero_state.invulnerable_ticks == 30,
		"dash-iframe: start_dash shortened %d external i-frames to %d" \
		% [30, _hero_state.invulnerable_ticks])
	_tick(11) ## The dash itself is long over (11 ticks).
	_expect(_hero_state.action == HeroCombatState.Action.IDLE,
		"dash-iframe: still dashing after 0.18 s")
	var result := _hit_hero(5.0)
	_expect(result.prevented, "dash-iframe: hit within external i-frames not prevented")
	_expect(is_equal_approx(_hero_state.hp, 10.0),
		"dash-iframe: hp %s after prevented hit" % _hero_state.hp)
	_expect(_hero_state.invulnerable_ticks == 19,
		"dash-iframe: %d external i-frames left, expected 19" % _hero_state.invulnerable_ticks)
	_setup()
	_hero_state.invulnerable_ticks = 3
	_controller.request_dash()
	_expect(_hero_state.invulnerable_ticks == 11,
		"dash-iframe: shorter external i-frames not extended to dash length (%s)" \
		% _hero_state.invulnerable_ticks)


func _test_dash_cancels_attack_recovery() -> void:
	_setup()
	_expect(_controller.request_attack(), "dash-cancel: attack rejected")
	_expect(_controller.request_dash(), "dash-cancel: dash during recovery rejected")
	_expect(_hero_state.action == HeroCombatState.Action.DASHING,
		"dash-cancel: action is %s" % _hero_state.action)
	_expect(not _controller.request_skill(), "dash-cancel: skill during dash accepted")


func _test_death() -> void:
	_setup()
	var result := _hit_hero(20.0)
	_expect(result.target_died, "death: target_died is false at 0 HP")
	_expect(not _hero_state.alive, "death: hero still alive")
	_expect(not _controller.request_attack(), "death: attack accepted")
	_expect(not _controller.request_skill(), "death: skill accepted")
	_expect(not _controller.request_dash(), "death: dash accepted")
	_controller.move_intent = Vector2.RIGHT
	_tick(10)
	_expect(_controller.position.is_equal_approx(Vector2.ZERO), "death: corpse moved to %s" % _controller.position)
	result = _hit_hero(5.0)
	_expect(result.prevented, "death: further damage not prevented")


func _test_knockback_overrides_intent_and_expires() -> void:
	_setup()
	_controller.move_intent = Vector2.RIGHT
	_enemy_attack.knockback_distance = 1.2
	var result := _hit_hero(5.0, Vector2.RIGHT)
	_expect(not result.prevented, "knockback: hit prevented")
	var ticks := maxi(1, roundi(CombatantState.KNOCKBACK_DURATION_SECONDS * 60))
	_expect(_hero_state.knockback_ticks == ticks,
		"knockback: ticks %s, expected %s" % [_hero_state.knockback_ticks, ticks])
	var step := 1.2 / ticks
	_tick(1)
	_expect(is_equal_approx(_controller.position.x, step),
		"knockback: x %s, expected %s after 1 tick" % [_controller.position.x, step])
	# While knockback runs, intent movement is fully suppressed — even after the
	# 2-tick hitstop expires — so the hero covers exactly the knockback distance.
	_tick(ticks - 1)
	_expect(_hero_state.knockback_ticks == 0,
		"knockback: %d ticks left after the duration" % _hero_state.knockback_ticks)
	_expect(is_equal_approx(_controller.position.x, 1.2),
		"knockback: x %s, expected exactly 1.2 m" % _controller.position.x)
	_expect(is_zero_approx(_controller.position.y), "knockback: y drifted to %s" % _controller.position.y)
	_tick(1)
	_expect(is_equal_approx(_controller.position.x, 1.2 + 5.0 / 60.0),
		"knockback: intent movement did not resume, x %s" % _controller.position.x)


func _test_knockback_blocked_by_dash_iframes() -> void:
	_setup()
	_controller.move_intent = Vector2.RIGHT
	_expect(_controller.request_dash(), "knockback-iframe: dash rejected")
	_enemy_attack.knockback_distance = 1.0
	var result := _hit_hero(5.0, Vector2.RIGHT)
	_expect(result.prevented, "knockback-iframe: hit during dash not prevented")
	_expect(_hero_state.knockback_ticks == 0,
		"knockback-iframe: knockback applied through i-frames (%d ticks)" \
		% _hero_state.knockback_ticks)
	_tick(11)
	_expect(_controller.position.is_equal_approx(Vector2(3.0, 0.0)),
		"knockback-iframe: dash distance changed, position %s" % _controller.position)


func _test_knockback_stacks_with_dash() -> void:
	# A knockback already in flight when the dash starts keeps carrying the hero:
	# the dash step and the knockback offset are additive.
	_setup()
	_controller.move_intent = Vector2.RIGHT
	_enemy_attack.knockback_distance = 1.2
	_hit_hero(5.0, Vector2.RIGHT)
	_tick(3) ## Ride out the 2-tick hitstop; 3 of 7 knockback ticks are spent.
	_expect(_controller.request_dash(), "knockback-dash: dash during knockback rejected")
	_tick(11) ## The full dash (11 ticks); 4 knockback ticks overlap its start.
	_expect(_controller.position.is_equal_approx(Vector2(4.2, 0.0)),
		"knockback-dash: position %s, expected (4.2, 0) = 1.2 knockback + 3 dash" \
		% _controller.position)
	_expect(_hero_state.knockback_ticks == 0,
		"knockback-dash: %d knockback ticks left after the dash" % _hero_state.knockback_ticks)


func _test_knockback_displaces_pocket_hero() -> void:
	# Like the pocket dash carry-over, knockback keeps displacing a benched hero.
	_setup()
	_hero_state.apply_knockback(1.2, Vector2.RIGHT)
	_controller.tick(false, _damage_system)
	_expect(is_equal_approx(_controller.position.x, 1.2 / 7.0),
		"knockback-pocket: x %s after 1 pocket tick" % _controller.position.x)
	_tick(6)
	_expect(_controller.position.is_equal_approx(Vector2(1.2, 0.0)),
		"knockback-pocket: position %s, expected (1.2, 0)" % _controller.position)


func _test_input_map_registration() -> void:
	HeroInput.register()
	var counts := {
		HeroInput.MOVE_LEFT: 2, HeroInput.MOVE_RIGHT: 2, HeroInput.MOVE_UP: 2, HeroInput.MOVE_DOWN: 2,
		HeroInput.ATTACK: 2, HeroInput.SKILL: 2, HeroInput.DASH: 2,
		HeroInput.SWAP_1: 1, HeroInput.SWAP_2: 1, HeroInput.SWAP_3: 1,
		HeroInput.SWAP_NEXT: 1, HeroInput.SWAP_PREV: 1,
	}
	for action: StringName in counts:
		_expect(InputMap.has_action(action), "input: action %s missing" % action)
	HeroInput.register() ## Must be idempotent: no duplicate events on re-register.
	for action: StringName in counts:
		var event_count := InputMap.action_get_events(action).size()
		_expect(event_count == counts[action], "input: action %s has %d events, expected %d" \
				% [action, event_count, counts[action]])


func _setup() -> void:
	_status_config = StatusConfig.new()
	_damage_system = DamageSystem.new()
	_damage_system.status_config = _status_config
	var hero_definition: HeroDefinition = load(HERO_TRES)
	_hero_state = HeroCombatState.new()
	_hero_state.configure_hero(hero_definition, 1, _status_config)
	_damage_system.register_combatant(_hero_state)
	_controller = HeroActionController.new()
	_controller.setup(_hero_state, Vector2.ZERO)
	_controller.attack_fired.connect(_on_attack_fired)
	_controller.skill_fired.connect(_on_skill_fired)
	var enemy_definition := CombatantDefinition.new()
	enemy_definition.max_hp = 10000.0
	enemy_definition.max_poise = 10000.0
	_enemy_state = CombatantState.new()
	_enemy_state.configure(enemy_definition, 99, CombatTypes.Faction.ENEMY, _status_config)
	_enemy_attack = AttackDefinition.new()
	_enemy_attack.id = &"enemy_hit"
	_enemy_attack.base_damage = 0.0
	_attack_hits.clear()
	_skill_hits.clear()


func _on_attack_fired(attack: AttackDefinition, _origin: Vector2, _direction: Vector2) -> void:
	var result := DamageResult.new()
	_damage_system.deal(attack, _hero_state, _enemy_state, result)
	_attack_hits.append(result)


func _on_skill_fired(attack: AttackDefinition, _origin: Vector2, _direction: Vector2) -> void:
	var result := DamageResult.new()
	_damage_system.deal(attack, _hero_state, _enemy_state, result)
	_skill_hits.append(result)


func _hit_hero(damage: float, knockback_direction := Vector2.ZERO) -> DamageResult:
	_enemy_attack.base_damage = damage
	var result := DamageResult.new()
	_damage_system.deal(_enemy_attack, _enemy_state, _hero_state, result, 1.0,
			knockback_direction)
	return result


func _tick(count: int) -> void:
	for _i: int in count:
		_controller.tick(true, _damage_system)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
