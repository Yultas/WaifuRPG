extends SceneTree
## Behavior tests of BasicEnemy against a dummy hero combatant on a flat open room:
## idle outside detection_range, chase inside it, immobile telegraph without damage,
## exactly one resolved hit per attack through DamageSystem with the expected type and
## values, attack_cooldown between hits, post-telegraph re-validation (hero leaving
## attack_range deals no damage), i-frames and death preventing the hit, stun freezing
## the telegraph, knockback sliding the enemy (through a stagger, clamped by
## RoomCollision walls), the strike pushing the hero combatant away
## (attack_knockback from EnemyDefinition), deterministic nearest-target selection among
## multiple heroes (actor-id tie-break and death retargeting), and a hero without a combat
## state causing no error.
## Run: godot --headless --fixed-fps 60 --path . -s res://tests/test_basic_enemy.gd
## (--fixed-fps makes physics run as fast as possible instead of in real time.)

const T := preload("res://src/dungeon/dungeon_types.gd")
const ENEMY_TRES := "res://data/enemies/basic_enemy.tres"
const ROOM := Vector2i(24, 24)
const ENEMY_CELL := Vector2i(6, 12)
## Cell centers are at (n + 0.5) * CELL_PIXELS.
const IDLE_CELL := Vector2i(6, 21) ## 9 m away, outside detection_range (8 m).
const CHASE_CELL := Vector2i(6, 17) ## 5 m away: inside detection, outside attack_range.
const MELEE_CELL := Vector2i(6, 13) ## 1 m away: inside attack_range (1.5 m).
const HERO_HP := 1000.0 ## High enough that no test sequence kills the dummy.

var _failures := 0


## A hero stand-in: BasicEnemy pulls the combat state off the watched node.
class DummyHero extends Node2D:
	var combatant_state: CombatantState


class StrikeObserver extends ModifierHandler:
	var enemy: BasicEnemy
	var calls := 0
	var observed_state := -1
	var observed_windup := -1

	func after_damage(_source: CombatantState, _target: CombatantState,
			_actual_damage: float) -> void:
		calls += 1
		observed_state = enemy.state
		var brain: EnemyBrain = enemy.get("_brain")
		observed_windup = brain.telegraph_ticks


var _world: Node2D
var _enemy: BasicEnemy
var _hero: DummyHero
var _plain_hero: Node2D
var _definition: EnemyDefinition
var _damage_system: DamageSystem


func _initialize() -> void:
	_definition = load(ENEMY_TRES)
	await _test_idle_outside_detection()
	await _test_chase_inside_detection()
	await _test_telegraph_is_immobile_and_harmless()
	await _test_one_hit_with_resolved_values()
	await _test_attack_cooldown_between_hits()
	await _test_hero_leaving_range_during_telegraph()
	await _test_invulnerable_hero_takes_no_hit()
	await _test_dead_hero_takes_no_hit()
	await _test_stun_freezes_telegraph()
	await _test_strike_applies_knockback()
	await _test_knockback_displaces_enemy()
	await _test_knockback_slides_through_stagger()
	await _test_knockback_stops_at_wall()
	await _test_multiple_heroes_choose_nearest()
	await _test_hero_without_combat_state()
	await _test_shared_definition_runtime_isolation()
	await _test_strike_callback_and_result_reuse()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_idle_outside_detection() -> void:
	await _setup(IDLE_CELL, true)
	var start := _enemy.position
	await _step(30)
	_expect(_enemy.state == BasicEnemy.State.IDLE, "idle: state is %s" % _enemy.state)
	_expect(_enemy.position.distance_to(start) < 0.001,
		"idle: enemy moved %s px" % _enemy.position.distance_to(start))
	_expect(_hero_hp() == HERO_HP, "idle: dummy took damage")
	await _teardown()


func _test_chase_inside_detection() -> void:
	await _setup(CHASE_CELL, true)
	var start_dist := _enemy.position.distance_to(_hero.position)
	# Navigation registration is async: poll until the enemy actually closes in.
	var closed_in := false
	for _i in 90:
		await physics_frame
		_enemy.tick()
		if _enemy.position.distance_to(_hero.position) < start_dist - 20.0:
			closed_in = true
			break
	_expect(closed_in, "chase: enemy did not close in from %s px" % start_dist)
	_expect(_enemy.state == BasicEnemy.State.CHASE, "chase: state is %s" % _enemy.state)
	_expect(_hero_hp() == HERO_HP, "chase: dummy took damage")
	await _teardown()


func _test_telegraph_is_immobile_and_harmless() -> void:
	await _setup(MELEE_CELL, true)
	await _step(3)
	_expect(_enemy.state == BasicEnemy.State.TELEGRAPH, "telegraph: state is %s" % _enemy.state)
	var start := _enemy.position
	# Half the telegraph: no hit yet, no movement.
	await _step(15)
	_expect(_enemy.state == BasicEnemy.State.TELEGRAPH, "telegraph: ended early")
	_expect(_enemy.position.distance_to(start) < 0.001,
		"telegraph: enemy moved %s px" % _enemy.position.distance_to(start))
	_expect(_hero_hp() == HERO_HP, "telegraph: damage landed early")
	await _teardown()


func _test_one_hit_with_resolved_values() -> void:
	await _setup(MELEE_CELL, true)
	var hp_before := _hero_hp()
	var poise_before := _hero.combatant_state.poise
	await _step_until_hit(90)
	_expect(_hero_hp() < hp_before, "hit: dummy took no damage")
	if _hero_hp() < hp_before:
		_expect(is_equal_approx(hp_before - _hero_hp(), _definition.attack_damage),
			"hit: damage %s, expected %s" % [hp_before - _hero_hp(), _definition.attack_damage])
		_expect(is_equal_approx(poise_before - _hero.combatant_state.poise,
				_definition.poise_damage),
			"hit: poise %s, expected %s" % [poise_before - _hero.combatant_state.poise,
				_definition.poise_damage])
		_expect(_enemy.last_result.damage_type == CombatTypes.DamageType.PHYSICAL,
			"hit: type %s, expected PHYSICAL" % _enemy.last_result.damage_type)
		_expect(not _enemy.last_result.prevented, "hit: result marked prevented")
	_expect(_enemy.state == BasicEnemy.State.COOLDOWN, "hit: state is %s" % _enemy.state)
	var hp_after_hit := _hero_hp()
	await _step(2)
	_expect(_hero_hp() == hp_after_hit, "hit: extra damage after cooldown start")
	await _teardown()


func _test_attack_cooldown_between_hits() -> void:
	await _setup(MELEE_CELL, true)
	await _step_until_hit(90)
	# Cooldown (1.5 s = 90 ticks) plus the next telegraph (0.5 s = 30 ticks) must pass
	# before the second hit: 84 ticks after the first hit there is still exactly one.
	await _step(84)
	_expect(_hero_hp() == HERO_HP - _definition.attack_damage, "cooldown: second hit landed early")
	await _step_until_hit(120)
	_expect(is_equal_approx(_hero_hp(), HERO_HP - 2.0 * _definition.attack_damage),
		"cooldown: got no second hit")
	await _teardown()


func _test_hero_leaving_range_during_telegraph() -> void:
	await _setup(MELEE_CELL, true)
	await _step(3)
	_expect(_enemy.state == BasicEnemy.State.TELEGRAPH, "leave: state is %s" % _enemy.state)
	# The hero dashes out of attack_range while the enemy is winding up.
	_hero.position = (Vector2(IDLE_CELL) + Vector2(0.5, 0.5)) * WorldUnits.CELL_PIXELS
	await _step(60)
	_expect(_hero_hp() == HERO_HP, "leave: hit landed out of range")
	_expect(_enemy.state == BasicEnemy.State.COOLDOWN, "leave: state is %s" % _enemy.state)
	await _teardown()


func _test_invulnerable_hero_takes_no_hit() -> void:
	await _setup(MELEE_CELL, true)
	_hero.combatant_state.invulnerable_ticks = 300
	await _step_until_hit(90)
	_expect(_hero_hp() == HERO_HP, "i-frames: hit landed through i-frames")
	_expect(_enemy.last_result.prevented, "i-frames: result not marked prevented")
	await _teardown()


func _test_dead_hero_takes_no_hit() -> void:
	await _setup(MELEE_CELL, true)
	_hero.combatant_state.alive = false
	await _step(60)
	_expect(_hero_hp() == HERO_HP, "dead: dead dummy took damage")
	_expect(_enemy.get("_hero") == null, "dead: dead hero remained selected")
	await _teardown()


func _test_stun_freezes_telegraph() -> void:
	await _setup(MELEE_CELL, true)
	await _step(3)
	_expect(_enemy.state == BasicEnemy.State.TELEGRAPH, "stun: state is %s" % _enemy.state)
	_enemy.combat.statuses.apply(CombatTypes.Status.STUN, 1, -1)
	await _step(29)
	_expect(_hero_hp() == HERO_HP, "stun: hit landed while stunned")
	_expect(_enemy.state == BasicEnemy.State.TELEGRAPH, "stun: telegraph did not freeze")
	# Stagger lasts 0.4 s (24 ticks); the remaining windup then finishes.
	await _step_until_hit(60)
	_expect(_hero_hp() < HERO_HP, "stun: no hit after stun expired")
	await _teardown()


func _test_strike_applies_knockback() -> void:
	# The resolved hit pushes the hero combatant away from the enemy: a full
	# attack_knockback over KNOCKBACK_DURATION_SECONDS, along the strike direction.
	await _setup(MELEE_CELL, true)
	await _step_until_hit(90)
	_expect(_hero_hp() < HERO_HP, "knockback-hit: dummy took no damage")
	var ticks := maxi(1, roundi(CombatantState.KNOCKBACK_DURATION_SECONDS * 60))
	_expect(_hero.combatant_state.knockback_ticks == ticks,
		"knockback-hit: ticks %s, expected %s" % [_hero.combatant_state.knockback_ticks, ticks])
	var offset := _hero.combatant_state.knockback_offset()
	# Hero stands directly below the enemy (cells (6,13) and (6,12)): the push is
	# straight down, 0.5 m over the whole knockback.
	_expect(is_zero_approx(offset.x), "knockback-hit: x %s, expected 0" % offset.x)
	_expect(is_equal_approx(offset.y, _definition.attack_knockback / ticks),
		"knockback-hit: y %s, expected %s" % [offset.y, _definition.attack_knockback / ticks])
	await _teardown()


func _test_knockback_displaces_enemy() -> void:
	await _setup(IDLE_CELL, true)
	var start := _enemy.meters()
	_enemy.combat.apply_knockback(1.0, Vector2.LEFT)
	var ticks := maxi(1, roundi(CombatantState.KNOCKBACK_DURATION_SECONDS * 60))
	await _step(ticks)
	_expect(_enemy.combat.knockback_ticks == 0,
		"knockback: %d ticks left after the duration" % _enemy.combat.knockback_ticks)
	var moved := start.x - _enemy.meters().x
	_expect(is_equal_approx(moved, 1.0), "knockback: moved %s m, expected 1.0" % moved)
	_expect(is_equal_approx(start.y, _enemy.meters().y),
		"knockback: y drifted to %s" % _enemy.meters().y)
	# Knockback is a one-shot displacement: once it expires the enemy stands still.
	var rest := _enemy.meters()
	await _step(5)
	_expect(_enemy.meters().distance_to(rest) < 0.001,
		"knockback: enemy kept sliding to %s" % _enemy.meters())
	await _teardown()


func _test_knockback_slides_through_stagger() -> void:
	# Stun freezes the state machine, but knockback is forced displacement: a
	# staggered enemy is still pushed the full distance.
	await _setup(IDLE_CELL, true)
	var start := _enemy.meters()
	_enemy.combat.statuses.apply(CombatTypes.Status.STUN, 1, -1)
	_enemy.combat.apply_knockback(1.0, Vector2.LEFT)
	await _step(maxi(1, roundi(CombatantState.KNOCKBACK_DURATION_SECONDS * 60)))
	_expect(_enemy.state == BasicEnemy.State.IDLE,
		"knockback-stagger: state is %s, expected IDLE (machine frozen)" % _enemy.state)
	_expect(is_equal_approx(start.x - _enemy.meters().x, 1.0),
		"knockback-stagger: moved %s m, expected 1.0 through the stun" \
		% (start.x - _enemy.meters().x))
	await _teardown()


func _test_knockback_stops_at_wall() -> void:
	# Interior wall line sits at x = 1 cell; the knocked enemy must clamp against
	# it (center at wall + radius) instead of passing through.
	await _setup(IDLE_CELL, true, true)
	var start := _enemy.meters()
	_enemy.combat.apply_knockback(8.0, Vector2.LEFT)
	await _step(15)
	var x := _enemy.meters().x
	var wall_x := WorldUnits.CELL_SIZE + _definition.radius
	_expect(x < start.x - 1.0, "knockback-wall: enemy did not slide, x %s" % x)
	_expect(absf(x - wall_x) < 0.05,
		"knockback-wall: x %s, expected %s (wall + radius)" % [x, wall_x])
	await _teardown()


func _test_multiple_heroes_choose_nearest() -> void:
	await _setup(CHASE_CELL, true)
	var other := DummyHero.new()
	_world.add_child(other)
	other.position = (Vector2(MELEE_CELL) + Vector2(0.5, 0.5)) * WorldUnits.CELL_PIXELS
	other.combatant_state = CombatantState.new()
	var other_definition := CombatantDefinition.new()
	other_definition.max_hp = HERO_HP
	other.combatant_state.configure(other_definition, 102, CombatTypes.Faction.HERO,
			StatusConfig.new(), 60)
	_damage_system.register_combatant(other.combatant_state)
	var targets: Array[Node2D] = [_hero, other]
	_enemy.set_targets(targets)
	await _step(1)
	_expect(_enemy.get("_hero") == other, "multi-target: nearest hero was not selected")
	other.position = (Vector2(IDLE_CELL) + Vector2(0.5, 0.5)) * WorldUnits.CELL_PIXELS
	await _step(1)
	_expect(_enemy.get("_hero") == _hero, "multi-target: target did not follow nearest hero")
	_hero.position = (Vector2(ENEMY_CELL + Vector2i(-1, 0)) + Vector2(0.5, 0.5)) \
			* WorldUnits.CELL_PIXELS
	other.position = (Vector2(ENEMY_CELL + Vector2i(1, 0)) + Vector2(0.5, 0.5)) \
			* WorldUnits.CELL_PIXELS
	await _step(1)
	_expect(_enemy.get("_hero") == _hero, "multi-target: equal distance did not use actor id")
	_hero.combatant_state.alive = false
	await _step(1)
	_expect(_enemy.get("_hero") == other, "multi-target: dead hero remained selected")
	other.combatant_state.alive = false
	await _step(1)
	_expect(_enemy.get("_hero") == null, "multi-target: target remained with no living heroes")
	await _teardown()


func _test_hero_without_combat_state() -> void:
	await _setup_plain(MELEE_CELL)
	# Through the telegraph and past the strike: no combat state, no crash.
	await _step(int((_definition.telegraph_duration + 0.2) * 60.0))
	_expect(_enemy.state == BasicEnemy.State.COOLDOWN,
		"no combat state: state is %s" % _enemy.state)
	await _teardown()


## Shared balance never shares mutable brain, attack, result, target or combat state.
func _test_shared_definition_runtime_isolation() -> void:
	await _setup(MELEE_CELL, true)
	var other := BasicEnemy.new()
	other.definition = _definition
	other.damage_system = _damage_system
	_world.add_child(other)
	var targets: Array[Node2D] = [_hero]
	other.enter_room(_enemy.map, WorldUnits.PIXELS_PER_METER, ENEMY_CELL, targets, 101)
	_expect(other.definition == _enemy.definition, "isolation: balance not shared")
	_expect(other.combat != _enemy.combat, "isolation: combat shared")
	_expect(other.get("_attack") != _enemy.get("_attack"), "isolation: attack shared")
	_expect(other.last_result != _enemy.last_result, "isolation: damage result shared")
	var other_result := other.last_result
	await _step(2)
	_expect(_enemy.state == BasicEnemy.State.TELEGRAPH, "isolation: first not winding up")
	_expect(other.state == BasicEnemy.State.IDLE, "isolation: unstepped brain advanced")
	_expect(other.get("_hero") == null, "isolation: unstepped target changed")
	other.tick()
	other.tick()
	var other_brain: EnemyBrain = other.get("_brain")
	var full_windup := other_brain.telegraph_ticks
	await _step_until_hit(roundi(_definition.telegraph_duration * 60.0) + 1)
	_expect(_hero_hp() < HERO_HP, "isolation: first did not strike")
	_expect(other.state == BasicEnemy.State.TELEGRAPH, "isolation: second state advanced")
	_expect(other_brain.telegraph_ticks == full_windup, "isolation: second timer advanced")
	_expect(other.last_result == other_result, "isolation: second result replaced")
	_expect(other.last_result.actual_damage == 0.0, "isolation: second result mutated")
	var first_attack: AttackDefinition = _enemy.get("_attack")
	var other_attack: AttackDefinition = other.get("_attack")
	first_attack.base_damage += 1.0
	_expect(other_attack.base_damage == _definition.attack_damage,
			"isolation: attack mutation reached other enemy or balance")
	other.set_targets([])
	_expect(_enemy.get("_hero") == _hero, "isolation: target mutation reached first")
	other.enter_room(_enemy.map, WorldUnits.PIXELS_PER_METER, ENEMY_CELL, targets, 101)
	_expect(other_brain.state == BasicEnemy.State.IDLE and other_brain.telegraph_ticks == 0,
			"isolation: room entry did not reset brain")
	_expect(_enemy.state == BasicEnemy.State.COOLDOWN, "isolation: reset reached first")
	await _teardown()


func _test_strike_callback_and_result_reuse() -> void:
	await _setup(MELEE_CELL, true)
	var observer := StrikeObserver.new()
	observer.enemy = _enemy
	var modifier := ModifierDefinition.new()
	modifier.after_damage_handler = observer
	_enemy.combat.modifiers.add(modifier)
	var result := _enemy.last_result
	var windup_ticks := maxi(1, roundi(_definition.telegraph_duration * 60.0))
	await _step_until_hit(windup_ticks + 3)
	_expect(observer.calls == 1, "callback: strike did not notify exactly once")
	_expect(observer.observed_state == BasicEnemy.State.TELEGRAPH,
			"callback: cooldown started before dealing damage")
	_expect(observer.observed_windup == 0, "callback: windup had not expired")
	_expect(_enemy.state == BasicEnemy.State.COOLDOWN, "callback: no cooldown after damage")
	_expect(_enemy.last_result == result, "result: object replaced by hit")
	var damage := result.actual_damage
	await _step(maxi(1, roundi(_definition.attack_cooldown * 60.0)))
	_expect(_enemy.state == BasicEnemy.State.TELEGRAPH, "result: second windup did not start")
	_hero.position = (Vector2(IDLE_CELL) + Vector2(0.5, 0.5)) * WorldUnits.CELL_PIXELS
	await _step(windup_ticks)
	_expect(_enemy.state == BasicEnemy.State.COOLDOWN, "result: miss skipped cooldown")
	_expect(observer.calls == 1, "result: miss notified damage callback")
	_expect(_enemy.last_result == result and result.actual_damage == damage,
			"result: pre-deal no-op cleared or replaced the previous hit")
	await _teardown()


func _hero_hp() -> float:
	return _hero.combatant_state.hp


## Fresh room, navigation region, damage system, enemy and hero per test.
## with_walls also builds the RoomCollision static bodies (off by default so the
## existing tests keep running against an otherwise empty physics space).
func _setup(hero_cell: Vector2i, with_combat: bool, with_walls := false) -> void:
	var map := _make_map()
	_world = Node2D.new()
	root.add_child(_world)
	_world.add_child(_make_navigation(map))
	if with_walls:
		_world.add_child(RoomCollision.build_2d(map, WorldUnits.PIXELS_PER_METER))
	_damage_system = DamageSystem.new()
	_enemy = BasicEnemy.new()
	_enemy.definition = _definition
	_enemy.damage_system = _damage_system
	_world.add_child(_enemy)
	_hero = DummyHero.new()
	_world.add_child(_hero)
	_hero.position = (Vector2(hero_cell) + Vector2(0.5, 0.5)) * WorldUnits.CELL_PIXELS
	if with_combat:
		var hero_definition := CombatantDefinition.new()
		hero_definition.max_hp = HERO_HP
		_hero.combatant_state = CombatantState.new()
		_hero.combatant_state.configure(hero_definition, 1, CombatTypes.Faction.HERO,
				StatusConfig.new(), 60)
		_damage_system.register_combatant(_hero.combatant_state)
	var targets: Array[Node2D] = [_hero]
	_enemy.enter_room(map, WorldUnits.PIXELS_PER_METER, ENEMY_CELL, targets, 100)
	# Let the navigation region register on the map before any path query.
	await physics_frame
	await physics_frame


## Hero is a plain Node2D exposing no combat state.
func _setup_plain(hero_cell: Vector2i) -> void:
	var map := _make_map()
	_world = Node2D.new()
	root.add_child(_world)
	_world.add_child(_make_navigation(map))
	_damage_system = DamageSystem.new()
	_enemy = BasicEnemy.new()
	_enemy.definition = _definition
	_enemy.damage_system = _damage_system
	_world.add_child(_enemy)
	_plain_hero = Node2D.new()
	_world.add_child(_plain_hero)
	_plain_hero.position = (Vector2(hero_cell) + Vector2(0.5, 0.5)) * WorldUnits.CELL_PIXELS
	var targets: Array[Node2D] = [_plain_hero]
	_enemy.enter_room(map, WorldUnits.PIXELS_PER_METER, ENEMY_CELL, targets, 101)
	await physics_frame
	await physics_frame


func _teardown() -> void:
	_world.queue_free()
	await process_frame
	_world = null
	_enemy = null
	_hero = null
	_plain_hero = null
	_damage_system = null


func _make_map() -> RoomMap:
	var map := RoomMap.new(ROOM)
	for i in map.cell_count():
		map.terrain[i] = T.Terrain.LAND
	for x in ROOM.x:
		for y in [0, ROOM.y - 1]:
			map.wall[map.idx(Vector2i(x, y))] = 1
	for y in ROOM.y:
		for x in [0, ROOM.x - 1]:
			map.wall[map.idx(Vector2i(x, y))] = 1
	map.center = ROOM / 2
	return map


## NavigationRegion2D covering the room interior (cell 1..22), in the same pixel space.
func _make_navigation(map: RoomMap) -> NavigationRegion2D:
	var region := NavigationRegion2D.new()
	var lo := 1.0 * WorldUnits.CELL_PIXELS
	var hi := Vector2(map.size - Vector2i(1, 1)) * WorldUnits.CELL_PIXELS
	var source := NavigationMeshSourceGeometryData2D.new()
	source.add_traversable_outline(PackedVector2Array([Vector2(lo, lo), Vector2(hi.x, lo),
		Vector2(hi.x, hi.y), Vector2(lo, hi.y)]))
	var nav_poly := NavigationPolygon.new()
	NavigationServer2D.bake_from_source_geometry_data(nav_poly, source)
	region.navigation_polygon = nav_poly
	return region


func _step(frames: int) -> void:
	for _i in frames:
		await physics_frame
		_enemy.tick()


## Steps until the dummy takes damage or the frame budget runs out.
func _step_until_hit(budget: int) -> void:
	var before := _hero_hp()
	for _i in budget:
		await physics_frame
		_enemy.tick()
		if _hero_hp() < before:
			return


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
