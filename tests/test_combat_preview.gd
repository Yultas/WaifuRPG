extends SceneTree
## Headless integration test of the playable combat preview
## (scenes/debug/dungeon_preview.tscn): a 3-hero PartyController and every BasicEnemy
## share one DamageSystem/StatusConfig, HeroInput actions are registered, movement,
## manual attack (through a transient Hitbox2D + HitRegistry + enemy Hurtbox2D), skill,
## dash and swaps work in the real room (RoomCollision walls, RoomNavigation mesh),
## pocket cooldowns keep ticking, enemy telegraphs strike the active hero through the
## HeroProxy (killing it and auto-swapping), dead enemies despawn, room transitions
## respawn the combat setup in the next room with fresh unique actor ids (the DamageSystem
## source registry holds exactly the live ids), a dash swapped into the pocket keeps
## displacing the benched hero until it ticks out (the HeroActionController pocket-dash
## contract the CombatHeroView relies on), and a landed hit really knocks the target back
## (full data-driven distance on open ground, clamped against a room wall, never through).
## Run: godot --headless --fixed-fps 60 --path . -s res://tests/test_combat_preview.gd
## (--fixed-fps makes physics run as fast as possible instead of in real time.)

const PREVIEW_SCENE := "res://scenes/debug/dungeon_preview.tscn"
const ENEMY_HP := 60.0

var _failures := 0
var _preview: Node2D
var _guarding := false
## While guarding, every live enemy except this one is re-stunned every physics tick,
## so background enemies can never wander into a hitbox or strike the hero mid-test.
var _guard_except: BasicEnemy = null


func _initialize() -> void:
	_run()


func _run() -> void:
	_preview = load(PREVIEW_SCENE).instantiate()
	root.add_child(_preview)
	await _frames(5)
	_test_input_registered()
	_test_party_and_enemies()
	await _test_movement()
	await _test_attack()
	await _test_skill()
	await _test_knockback_and_walls()
	_stop_guard()
	_slay_all()
	await _frames(30)
	_expect(_enemies().is_empty(), "death: enemies not despawned after kill")
	await _test_dash()
	await _test_swap_and_pocket_cooldowns()
	await _test_pocket_dash()
	await _test_room_transition()
	_start_guard(null)
	await _test_enemy_strikes_kill_and_swap()
	_stop_guard()
	_slay_all()
	await _frames(30)
	_expect(_enemies().is_empty(), "death2: enemies not despawned after kill")
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_input_registered() -> void:
	for action: StringName in [HeroInput.MOVE_LEFT, HeroInput.MOVE_RIGHT, HeroInput.MOVE_UP,
			HeroInput.MOVE_DOWN, HeroInput.ATTACK, HeroInput.SKILL, HeroInput.DASH,
			HeroInput.SWAP_1, HeroInput.SWAP_2, HeroInput.SWAP_3]:
		_expect(InputMap.has_action(action), "input: action %s missing" % action)


func _test_party_and_enemies() -> void:
	var party := _party()
	_expect(party.states.size() == 3, "party: %d heroes, expected 3" % party.states.size())
	_expect(party.damage_system == _preview.get("_damage_system"),
			"party: heroes not on the preview DamageSystem")
	_expect(party.states[0].statuses.config == _preview.get("_damage_system").status_config,
			"party: heroes do not share the preview StatusConfig")
	var enemies := _enemies()
	_expect(enemies.size() >= 3, "spawn: %d enemies in the start room, expected >= 3" % enemies.size())
	var map: RoomMap = _preview.get("_room").map
	var proxy: Node2D = _preview.get("_hero_proxy")
	for enemy: BasicEnemy in enemies:
		_expect(enemy.damage_system == _preview.get("_damage_system"),
				"spawn: enemy without the shared DamageSystem")
		_expect(enemy.combat != null, "spawn: enemy has no CombatantState")
		_expect(map.is_walkable(enemy.cell()), "spawn: enemy on a blocked cell %s" % enemy.cell())
		_expect(enemy.get("_hero") == proxy, "spawn: enemy not watching the HeroProxy")
	var nav: RoomNavigation = _renderer().find_child("RoomNavigation", true, false)
	_expect(nav != null and nav.navigation_polygon.vertices.size() > 0,
			"navigation: RoomNavigation missing or empty")
	_expect_unique_sources("spawn")


func _test_movement() -> void:
	var x0: float = _party().controllers[0].position.x
	Input.action_press(HeroInput.MOVE_RIGHT)
	await _frames(30)
	Input.action_release(HeroInput.MOVE_RIGHT)
	var dx: float = _party().controllers[0].position.x - x0
	_expect(dx > 2.1 and dx < 3.1, "move: dx %.2f m in 0.5 s, expected ~2.5" % dx)
	var view: CombatHeroView = _views()[0]
	_expect(is_equal_approx(view.position.x, _party().controllers[0].position.x * view.pixels_per_meter),
			"move: view out of sync with the controller")


## One teleported enemy takes a single registered manual hit (60 -> 40), the telegraph
## stays harmless the whole window, then the enemy is slain so it cannot strike back.
func _test_attack() -> void:
	var party := _party()
	var view: CombatHeroView = _views()[0]
	var enemy: BasicEnemy = _enemies()[0]
	_start_guard(enemy)
	for other: BasicEnemy in _enemies():
		if other != enemy and other.combat != null and other.combat.alive:
			_park_far(other)
	enemy.position = view.position + Vector2(1.2 * view.pixels_per_meter, 0.0)
	enemy.velocity = Vector2.ZERO
	_expect(party.request_attack(), "attack: press rejected")
	var ticks := 0
	while enemy.combat.alive and is_equal_approx(enemy.combat.hp, ENEMY_HP) and ticks < 60:
		await _frames(1)
		ticks += 1
	_expect(is_equal_approx(enemy.combat.hp, ENEMY_HP - 20.0),
			"attack: enemy hp %.1f, expected 40 after one 20-dmg hit" % enemy.combat.hp)
	_expect(is_equal_approx(party.states[0].hp, 10.0),
			"telegraph: hero hp %.1f before the strike lands" % party.states[0].hp)
	_slay(enemy)


## Cast skill on a teleported enemy (60 -> 20, magical) and verify the cooldown starts.
func _test_skill() -> void:
	var party := _party()
	var view: CombatHeroView = _views()[0]
	# The manual attack arc lives a few ticks into this test: let it expire, and place
	# the target behind the hero (facing is RIGHT after the movement test).
	await _frames(10)
	var enemy: BasicEnemy = _enemies()[1]
	_guard_except = enemy
	enemy.position = view.position - Vector2(1.2 * view.pixels_per_meter, 0.0)
	enemy.velocity = Vector2.ZERO
	# The manual attack recovery must elapse before the cast can start.
	var ready := 0
	while (party.states[0].action != HeroCombatState.Action.IDLE
			or not party.states[0].can_act()) and ready < 90:
		await _frames(1)
		ready += 1
	_expect(party.request_skill(), "skill: press rejected")
	_expect(not party.request_skill(), "skill: press during cast accepted")
	var ticks := 0
	while enemy.combat.alive and is_equal_approx(enemy.combat.hp, ENEMY_HP) and ticks < 90:
		await _frames(1)
		ticks += 1
	_expect(is_equal_approx(enemy.combat.hp, ENEMY_HP - 40.0),
			"skill: enemy hp %.1f, expected 20 after a 40-dmg burst" % enemy.combat.hp)
	_expect(party.states[0].skill_cooldown_left > 0, "skill: cooldown not running after the fire")
	_expect(is_equal_approx(party.states[0].hp, 10.0), "skill: hero took damage mid-test")
	_slay(enemy)


## Knockback integration: the hero attack really shoves the enemy along the push
## direction for the full data-driven distance (the guard stuns every enemy, so
## nothing else moves it), and the same shove aimed at the east room wall clamps
## against it instead of covering the full distance or passing through.
func _test_knockback_and_walls() -> void:
	var party := _party()
	var map: RoomMap = _preview.get("_room").map
	var attack_knockback: float = party.states[0].hero_definition.attack.knockback_distance
	_expect(attack_knockback > 0.0, "knockback: hero attack has no knockback_distance in data")
	# The skill cast from the previous test must fully recover before the press.
	var ready := 0
	while (party.states[0].action != HeroCombatState.Action.IDLE
			or not party.states[0].can_act()) and ready < 120:
		await _frames(1)
		ready += 1
	_start_guard(null)  # stun every enemy: no chase drift, no telegraphed strike
	await _frames(2)
	var enemy: BasicEnemy = null
	for candidate: BasicEnemy in _enemies():
		if candidate.combat != null and candidate.combat.alive:
			enemy = candidate
			break
	_expect(enemy != null, "knockback: no live enemy left")
	if enemy == null:
		return
	# The enemy strike must carry its knockback distance from EnemyDefinition
	# (attack_knockback -> the attack BasicEnemy builds). The push itself is
	# unit-tested (the 10 HP hero dies to the 12-dmg strike before a push could
	# show), so here only the data wiring.
	var enemy_attack: AttackDefinition = enemy.get("_attack")
	_expect(enemy_attack != null
			and is_equal_approx(enemy_attack.knockback_distance,
					enemy.definition.attack_knockback)
			and enemy.definition.attack_knockback > 0.0,
			"knockback: enemy attack distance %s, expected attack_knockback %s" % [
					enemy_attack.knockback_distance if enemy_attack != null else "none",
					enemy.definition.attack_knockback])
	# Open ground: hero at the room center facing right, enemy 1.2 m to the right,
	# so the hitbox -> hurtbox direction is exactly +x.
	party.controllers[0].position = (Vector2(map.center) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE
	party.controllers[0].facing = Vector2.RIGHT
	enemy.position = party.controllers[0].position * enemy.pixels_per_meter \
			+ Vector2(1.2 * enemy.pixels_per_meter, 0.0)
	enemy.velocity = Vector2.ZERO
	var start: Vector2 = enemy.meters()
	_expect(party.request_attack(), "knockback: press rejected")
	var ticks := 0
	while enemy.combat.alive and is_equal_approx(enemy.combat.hp, ENEMY_HP) and ticks < 60:
		await _frames(1)
		ticks += 1
	_expect(is_equal_approx(enemy.combat.hp, ENEMY_HP - 20.0),
			"knockback: enemy hp %.1f, expected 40 after the hit" % enemy.combat.hp)
	await _frames(12)  # ride out the 0.12 s knockback fully
	var shove: Vector2 = enemy.meters() - start
	_expect(absf(shove.length() - attack_knockback) < 0.05,
			"knockback: shove %s m, expected %.2f" % [shove, attack_knockback])
	_expect(shove.x > 0.0 and absf(shove.y) < 0.05,
			"knockback: shove %s, expected straight +x" % shove)
	# Wall: a walkable cell whose east neighbor is solid ground (border wall,
	# cliff or prop — all of them physical walls in RoomCollision), with open floor
	# on the west for the hero. Scan a band near the east edge: the border ring is
	# thicker than one cell in some rooms.
	var edge := Vector2i(-1, -1)
	for x in range(map.size.x - 2, 0, -1):
		for y in range(1, map.size.y - 1):
			var c := Vector2i(x, y)
			if map.is_walkable(c) and not map.is_ground(c + Vector2i.RIGHT) \
					and not map.is_water(c + Vector2i.RIGHT) and map.is_walkable(c + Vector2i.LEFT):
				edge = c
				break
		if edge.x >= 0:
			break
	_expect(edge.x >= 0, "knockback-wall: no walkable east-edge cell with solid neighbor")
	if edge.x < 0:
		return
	var wall_inner := float(edge.x + 1)
	enemy.position = (Vector2(edge) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE \
			* enemy.pixels_per_meter
	enemy.velocity = Vector2.ZERO
	party.controllers[0].position = (Vector2(edge) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE \
			- Vector2(1.2, 0.0)
	party.controllers[0].facing = Vector2.RIGHT
	var view: CombatHeroView = _views()[0]
	# Snap the view too: a multi-cell jump would make move_and_slide catch a wall
	# en route and slide the hero off the aimed spot.
	view.position = party.controllers[0].position * view.pixels_per_meter
	await _frames(2)  # let the view confirm the hero spot (no clamp expected)
	var start_w: Vector2 = enemy.meters()
	# Attack recovery from the open-ground hit must elapse first.
	ready = 0
	while (party.states[0].action != HeroCombatState.Action.IDLE
			or not party.states[0].can_act()) and ready < 120:
		await _frames(1)
		ready += 1
	_expect(party.request_attack(), "knockback-wall: press rejected")
	ticks = 0
	while enemy.combat.alive and is_equal_approx(enemy.combat.hp, ENEMY_HP - 20.0) \
			and ticks < 60:
		await _frames(1)
		ticks += 1
	_expect(is_equal_approx(enemy.combat.hp, ENEMY_HP - 40.0),
			"knockback-wall: enemy hp %.1f, expected 20 after the second hit" % enemy.combat.hp)
	await _frames(12)
	var shove_w: Vector2 = enemy.meters() - start_w
	# The wall is well within the knockback distance: the enemy must stop at the
	# wall line minus its radius instead of covering the full distance or entering
	# the wall cell.
	var limit := wall_inner - enemy.definition.radius
	_expect(shove_w.x > 0.05, "knockback-wall: enemy did not slide, shove %s" % shove_w)
	_expect(shove_w.x < attack_knockback - 0.05,
			"knockback-wall: shove %s m was not clamped (full %.2f m)" % [shove_w.x, attack_knockback])
	_expect(enemy.meters().x < wall_inner,
			"knockback-wall: enemy center %.2f m inside the wall cell (< %.2f)" % [enemy.meters().x, wall_inner])
	_expect(absf(enemy.meters().x - limit) < 0.1,
			"knockback-wall: clamped at %.2f m, expected wall - radius = %.2f" % [enemy.meters().x, limit])
	# Put the hero back at the room center so the following dash test starts clean.
	party.controllers[0].position = (Vector2(map.center) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE
	view.position = party.controllers[0].position * view.pixels_per_meter


func _test_dash() -> void:
	var party := _party()
	var map: RoomMap = _preview.get("_room").map
	# Back to the room center so the dash has open ground.
	party.controllers[0].position = (Vector2(map.center) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE
	await _frames(2)
	Input.action_press(HeroInput.MOVE_RIGHT)
	await _frames(2)
	var x0: float = party.controllers[0].position.x
	_expect(party.request_dash(), "dash: press rejected")
	await _frames(15)
	Input.action_release(HeroInput.MOVE_RIGHT)
	var dx: float = party.controllers[0].position.x - x0
	_expect(absf(dx - 3.0) < 0.4, "dash: dx %.2f m, expected ~3.0" % dx)
	_expect(party.states[0].dash_cooldown_left > 0, "dash: cooldown not running")


func _test_swap_and_pocket_cooldowns() -> void:
	var party := _party()
	while party.swap_cooldown_left > 0:
		await _frames(1)
	_expect(party.request_swap_to(1), "swap: rejected after cooldown")
	_expect(not party.request_swap_to(2), "swap: accepted during cooldown")
	_expect(party.active_index() == 1, "swap: active index %d, expected 1" % party.active_index())
	# Hero 1 dashed before the swap; its dash cooldown must keep ticking in the pocket.
	var pocket_dash: int = party.states[0].dash_cooldown_left
	_expect(pocket_dash > 0, "pocket: hero 1 dash cooldown already 0")
	await _frames(10)
	_expect(party.states[0].dash_cooldown_left < pocket_dash,
			"pocket: hero 1 dash cooldown did not tick down")
	# Skill on the active hero, then swap it out: the skill cooldown runs in the pocket.
	_expect(party.request_skill(), "pocket: skill press rejected")
	var ticks := 0
	while party.states[1].skill_cooldown_left == 0 and ticks < 90:
		await _frames(1)
		ticks += 1
	_expect(party.states[1].skill_cooldown_left > 100,
			"pocket: skill cooldown %d ticks after the fire" % party.states[1].skill_cooldown_left)
	while party.swap_cooldown_left > 0:
		await _frames(1)
	_expect(party.request_swap_to(2), "pocket: swap back rejected")
	var pocket_skill: int = party.states[1].skill_cooldown_left
	await _frames(10)
	_expect(party.states[1].skill_cooldown_left < pocket_skill,
			"pocket: hero 2 skill cooldown did not tick down")
	_expect(party.active_index() == 2, "pocket: active index %d, expected 2" % party.active_index())


## Pocket-dash position contract: a dash survives a swap — HeroActionController keeps
## displacing the benched hero along dash_direction until the dash ticks out (no dash
## distance is lost), then the position freezes. The hidden CombatHeroView does not sync
## while pocket (it must not drag the advancing controller back), and catches up to the
## displaced controller position in one tick on re-activation.
func _test_pocket_dash() -> void:
	var party := _party()
	while party.swap_cooldown_left > 0:
		await _frames(1)
	var dasher := party.active_index()
	Input.action_press(HeroInput.MOVE_RIGHT)
	await _frames(2)
	_expect(party.request_dash(), "pocket-dash: press rejected")
	await _frames(2)
	_expect(party.states[dasher].action == HeroCombatState.Action.DASHING,
			"pocket-dash: hero %d not dashing before the swap" % (dasher + 1))
	var pos_at_swap: Vector2 = party.controllers[dasher].position
	var view: CombatHeroView = _views()[dasher]
	var view_pos_at_swap := view.position
	var target := (dasher + 1) % PartyController.PARTY_SIZE
	_expect(party.states[target].alive, "pocket-dash: swap target %d dead" % (target + 1))
	_expect(party.request_swap_to(target), "pocket-dash: swap out mid-dash rejected")
	# The pocket dash must keep covering distance along dash_direction (MOVE_RIGHT).
	var moved := false
	var ticks := 0
	while party.states[dasher].action == HeroCombatState.Action.DASHING and ticks < 60:
		await _frames(1)
		ticks += 1
		if not party.controllers[dasher].position.is_equal_approx(pos_at_swap):
			moved = true
		_expect(view.position.is_equal_approx(view_pos_at_swap),
				"pocket-dash: pocket view moved on tick %d" % ticks)
	_expect(moved, "pocket-dash: benched dash lost its displacement")
	_expect(party.states[dasher].action != HeroCombatState.Action.DASHING,
			"pocket-dash: dash did not run out in the pocket")
	_expect(party.controllers[dasher].position.x > pos_at_swap.x,
			"pocket-dash: pocket dash did not advance right")
	Input.action_release(HeroInput.MOVE_RIGHT)
	# After the dash expires the benched position freezes.
	var settled: Vector2 = party.controllers[dasher].position
	await _frames(5)
	_expect(party.controllers[dasher].position.is_equal_approx(settled),
			"pocket-dash: position moved after the dash expired")
	# Re-activating the dasher: the view catches up to the displaced controller
	# position instead of dragging the controller back to the stale view spot.
	while party.swap_cooldown_left > 0:
		await _frames(1)
	_expect(party.request_swap_to(dasher), "pocket-dash: swap back rejected")
	await _frames(2)
	_expect(is_equal_approx(view.position.x, party.controllers[dasher].position.x * view.pixels_per_meter),
			"pocket-dash: view did not catch up to the displaced controller")


func _test_room_transition() -> void:
	var party := _party()
	var room: RoomData = _preview.get("_room")
	var old_ids: Array[int] = []
	for enemy: BasicEnemy in _enemies():
		if enemy.combat != null:
			old_ids.append(enemy.combat.actor_id)
	var dir: int = room.neighbors.keys()[0]
	var next: RoomData = _preview.get("_dungeon").neighbor(room, dir)
	_preview.call("_show_room", next)
	await _frames(5)
	var enemies := _enemies()
	_expect(enemies.size() >= 3,
			"transition: %d enemies in the next room, expected >= 3" % enemies.size())
	for enemy: BasicEnemy in enemies:
		_expect(not old_ids.has(enemy.combat.actor_id),
				"transition: enemy actor_id %d reused from the previous room" % enemy.combat.actor_id)
	var map: RoomMap = _preview.get("_room").map
	for enemy: BasicEnemy in enemies:
		_expect(map.is_walkable(enemy.cell()),
				"transition: enemy on a blocked cell %s" % enemy.cell())
	var view: CombatHeroView = _views()[party.active_index()]
	_expect(is_equal_approx(view.position.x, party.controllers[party.active_index()].position.x * view.pixels_per_meter),
			"transition: view out of sync after the room change")
	for index: int in party.controllers.size():
		_expect(party.controllers[index].position.is_equal_approx(party.controllers[0].position),
				"transition: hero %d not placed at the entry cell" % index)
	_expect_unique_sources("transition")


## In the new room, adjacent enemies telegraph and strike the active hero through the
## HeroProxy; each 10 HP hero dies and the party auto-swaps, down to hero 3.
func _test_enemy_strikes_kill_and_swap() -> void:
	var party := _party()
	_strike_with(_enemies()[0], 0)
	_strike_with(_enemies()[1], 1)
	_expect(party.active_index() == 2, "strikes: active index %d, expected 2" % party.active_index())
	_expect(not party.party_alive() or party.states[2].alive,
			"strikes: hero 3 should stay alive")


## Parks every other enemy far away and waits for `victim_index` to die from the
## telegraphed strike, then confirms the auto-swap and removes the striker.
func _strike_with(enemy: BasicEnemy, victim_index: int) -> void:
	var party := _party()
	_guard_except = enemy
	for other: BasicEnemy in _enemies():
		if other != enemy and other.combat != null and other.combat.alive:
			_park_far(other)
	var view: CombatHeroView = _views()[victim_index]
	enemy.position = view.position + Vector2(1.2 * view.pixels_per_meter, 0.0)
	enemy.velocity = Vector2.ZERO
	var ticks := 0
	while party.states[victim_index].alive and ticks < 240:
		await _frames(1)
		ticks += 1
	_expect(not party.states[victim_index].alive,
			"strike: hero %d survived the point-blank strike" % (victim_index + 1))
	_expect(is_equal_approx(party.states[victim_index].hp, 0.0),
			"strike: hero %d hp %.1f, expected 0" % [victim_index + 1, party.states[victim_index].hp])
	ticks = 0
	while party.active_index() == victim_index and ticks < 60:
		await _frames(1)
		ticks += 1
	_expect(party.active_index() != victim_index,
			"strike: party did not auto-swap after hero %d died" % (victim_index + 1))
	_expect(_views()[party.active_index()].active,
			"strike: new active view not visible")
	_slay(enemy)


func _start_guard(except: BasicEnemy) -> void:
	_guard_except = except
	if not _guarding:
		physics_frame.connect(_guard_tick)
		_guarding = true


func _stop_guard() -> void:
	_guard_except = null
	if _guarding:
		physics_frame.disconnect(_guard_tick)
		_guarding = false


func _guard_tick() -> void:
	for enemy: BasicEnemy in _enemies():
		if enemy != _guard_except and is_instance_valid(enemy) \
				and enemy.combat != null and enemy.combat.alive:
			enemy.combat.statuses.apply(CombatTypes.Status.STUN, 1, -1)
			enemy.velocity = Vector2.ZERO


func _park_far(enemy: BasicEnemy) -> void:
	if enemy.combat == null or not enemy.combat.alive:
		return
	var map: RoomMap = _preview.get("_room").map
	var hero: CombatHeroView = _views()[_party().active_index()]
	var hero_cell := hero.cell()
	var best := hero_cell
	var best_dist := -1.0
	for i in map.cell_count():
		var c := map.cell(i)
		if not map.is_walkable(c):
			continue
		var dist := Vector2(c - hero_cell).length()
		if dist > best_dist:
			best_dist = dist
			best = c
	enemy.position = (Vector2(best) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE * enemy.pixels_per_meter
	enemy.velocity = Vector2.ZERO
	enemy.combat.statuses.apply(CombatTypes.Status.STUN, 1, -1)


func _slay(enemy: BasicEnemy) -> void:
	if enemy.combat == null or not enemy.combat.alive:
		return
	var attack := AttackDefinition.new()
	attack.id = &"test_slay"
	attack.base_damage = 10000.0
	attack.poise_damage = 0.0
	var result := DamageResult.new()
	_preview.get("_damage_system").deal(attack, _party().active_state(), enemy.combat, result)


func _slay_all() -> void:
	var snapshot: Array = (_enemies() as Array).duplicate()
	for enemy: BasicEnemy in snapshot:
		_slay(enemy)


func _party() -> PartyController:
	return _preview.get("_party")


func _enemies() -> Array:
	return _preview.get("_enemies")


func _views() -> Array:
	return _preview.get("_views")


func _renderer() -> RoomTileRenderer:
	return _preview.get("_renderer")


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)


## Every live combatant (party heroes plus spawned enemies) must own a unique actor_id,
## and the DamageSystem source registry must hold exactly those ids: no stale entries
## from previous rooms, nothing missing.
func _expect_unique_sources(context: String) -> void:
	var ids: Array[int] = []
	for state: HeroCombatState in _party().states:
		ids.append(state.actor_id)
	for enemy: BasicEnemy in _enemies():
		if enemy.combat != null:
			ids.append(enemy.combat.actor_id)
	for i: int in ids.size():
		for j: int in range(i + 1, ids.size()):
			_expect(ids[i] != ids[j],
					"%s: duplicate actor_id %d" % [context, ids[i]])
	var sources: Dictionary = _preview.get("_damage_system").get("_sources")
	var matches := sources.size() == ids.size()
	for id: int in ids:
		if not sources.has(id):
			matches = false
	_expect(matches, "%s: DamageSystem sources %d, expected exactly the %d live actor ids" % [
			context, sources.size(), ids.size()])
