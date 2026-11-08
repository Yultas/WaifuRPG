extends SceneTree
## R2 contract tests run through the real preview owner and real physics shape queries.
## Run: godot --headless --fixed-fps 60 --path . -s res://tests/test_enemy_simulation.gd

const PREVIEW = preload("res://scenes/debug/dungeon_preview.tscn")

var _failures := 0
var _assertions := 0
var _preview: Node2D
var _party: PartyController
var _context: EnemyRoomContext
var _damage: CountingDamageSystem
var _enemies: Array[BasicEnemy] = []
var _trace: Array[String] = []
var _origin := Vector2.ZERO


class CountingDamageSystem extends DamageSystem:
	var flush_calls := 0

	func flush() -> int:
		flush_calls += 1
		return super.flush()


class ProbeEnemy extends BasicEnemy:
	var trace: Array[String] = []
	var observed_position_m := Vector2.ZERO
	var observed_frame: EnemyRoomSnapshot

	func decide_tick(context: EnemyRoomContext) -> void:
		trace.append("decide:%d" % combat.actor_id)
		observed_frame = context.snapshot
		for sample: EnemyActorSample in context.snapshot.actors:
			if sample.faction == CombatTypes.Faction.HERO:
				observed_position_m = sample.position_m
		super.decide_tick(context)

	func plan_tick(context: EnemyRoomContext) -> void:
		trace.append("plan:%d" % combat.actor_id)
		super.plan_tick(context)

	func move_tick(context: EnemyRoomContext) -> void:
		trace.append("move:%d" % combat.actor_id)
		super.move_tick(context)

	func execute_tick(context: EnemyRoomContext) -> void:
		trace.append("execute:%d" % combat.actor_id)
		super.execute_tick(context)


class HitObserver extends ModifierHandler:
	var callback: Callable
	var calls := 0
	var victim_ids: Array[int] = []

	func after_damage(source: CombatantState, target: CombatantState, _amount: float) -> void:
		calls += 1
		victim_ids.append(target.actor_id)
		if callback.is_valid():
			callback.call(source, target)


func _initialize() -> void:
	_run()


func _run() -> void:
	await _setup()
	_test_shared_frame_and_input()
	_test_snapshot_values()
	_test_repeated_phases_and_forced_motion()
	_test_preparation_death()
	await _test_fresh_geometry()
	_test_source_guards_and_reentry()
	_test_room_boundary()
	for state: HeroCombatState in _party.states:
		state.modifiers.clear()
	for enemy: BasicEnemy in _enemies:
		if is_instance_valid(enemy):
			enemy.combat.modifiers.clear()
	_preview.queue_free()
	await process_frame
	call_deferred("_finish")


func _finish() -> void:
	print("ALL PASSED (%d assertions)" % _assertions if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures else 0)


func _setup() -> void:
	_preview = PREVIEW.instantiate()
	root.add_child(_preview)
	for i in 5:
		await physics_frame
	_preview.set_physics_process(false)
	(_preview.get("_input_node") as HeroInputNode).set_physics_process(false)
	for view: CombatHeroView in _preview.get("_views"):
		view.set_physics_process(false)
	_party = _preview.get("_party")
	_context = _preview.get("_room_context")
	_preview.call("_clear_enemies")
	await process_frame
	_damage = CountingDamageSystem.new()
	_damage.hitstop_ticks = 0
	_party.damage_system = _damage
	_preview.set("_damage_system", _damage)
	for state: HeroCombatState in _party.states:
		_damage.register_combatant(state)
	var map: RoomMap = _preview.get("_room").map
	_origin = (Vector2(map.center) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE
	for id: int in [1001, 1002]:
		var enemy := ProbeEnemy.new()
		enemy.trace = _trace
		enemy.definition = load("res://data/enemies/basic_enemy.tres").duplicate()
		enemy.damage_system = _damage
		var renderer: RoomTileRenderer = _preview.get("_renderer")
		renderer.actors.add_child(enemy)
		var targets: Array[Node2D] = [_preview.get("_hero_proxy")]
		enemy.enter_room(map, renderer.local_pixels_per_meter, map.center, targets, id)
		var hurtbox := Hurtbox2D.new()
		hurtbox.combatant = enemy.combat
		var shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = enemy.definition.radius * enemy.pixels_per_meter
		shape.shape = circle
		hurtbox.add_child(shape)
		enemy.add_child(hurtbox)
		_enemies.append(enemy)
	_preview.set("_enemies", _enemies)
	for i in 2:
		await physics_frame
	_reset()


func _view() -> CombatHeroView:
	return _preview.get("_views")[_party.active_index()]


func _reset() -> void:
	_preview.call("_clear_strikes")
	(_preview.get("_dying") as Array).clear()
	for state: HeroCombatState in _party.states:
		state.alive = true
	_party.swap_cooldown_left = 0
	if _party.active_index() != 0:
		_party.request_swap_to(0)
	_party.swap_cooldown_left = 0
	for i: int in _party.states.size():
		var state := _party.states[i]
		state.alive = true
		state.hp = 1000.0
		state.action = HeroCombatState.Action.IDLE
		state.action_ticks_left = 0
		state.statuses.clear()
		state.modifiers.clear()
		state.modifiers.stats.base_max_hp = 1000.0
		state.modifiers.rebuild()
		state.invulnerable_ticks = 0
		state.hitstop_ticks = 0
		state.knockback_ticks = 0
		state.dash_cooldown_left = 0
		_party.controllers[i].position = _origin
		_party.controllers[i].move_intent = Vector2.ZERO
		var view: CombatHeroView = _preview.get("_views")[i]
		view.position = _origin * view.pixels_per_meter
	_view().sync_proxy()
	for i: int in _enemies.size():
		var enemy := _enemies[i]
		enemy.combat.alive = true
		enemy.combat.hp = 60.0
		enemy.combat.statuses.clear()
		enemy.combat.modifiers.clear()
		enemy.combat.invulnerable_ticks = 0
		enemy.combat.hitstop_ticks = 0
		enemy.combat.knockback_ticks = 0
		enemy.position = (_origin + Vector2(3.0 + i, 0.0)) * enemy.pixels_per_meter
		enemy.velocity = Vector2.ZERO
		(enemy.get("_brain") as EnemyBrain).reset()
	_trace.clear()


func _advance(frame: HeroInputFrame = null) -> void:
	_preview.call("_on_hero_input_frame", frame if frame != null else HeroInputFrame.new())
	_preview.call("_physics_process", 1.0 / 60.0)


func _test_shared_frame_and_input() -> void:
	var enemy := _enemies[0] as ProbeEnemy
	var second := _enemies[1] as ProbeEnemy
	for body: BasicEnemy in _enemies:
		(body.get("_brain") as EnemyBrain).state = EnemyBrain.State.CHASE
		body.position = (_origin + Vector2(body.definition.attack_range + 0.04, 0.0)) * body.pixels_per_meter
	_enemies.reverse()
	var frame := HeroInputFrame.new()
	frame.move = Vector2.RIGHT
	var tick_before := _context.tick
	var flush_before := _damage.flush_calls
	_party.states[0].invulnerable_ticks = 9
	_party.states[1].dash_cooldown_left = 9
	_advance(frame)
	var step := _party.states[0].hero_definition.speed / 60.0
	_expect(_view().meters().is_equal_approx(_origin + Vector2(step, 0.0)), "hero advances exactly one step")
	_expect(_party.states[0].invulnerable_ticks == 8 and _party.states[1].dash_cooldown_left == 8, "active/pocket timers tick once")
	_expect(enemy.observed_position_m.is_equal_approx(_view().meters()) and second.observed_position_m.is_equal_approx(_view().meters()), "all observations use synchronized current hero")
	_expect(enemy.observed_frame == second.observed_frame, "one shared frame identity")
	_expect(enemy.state == EnemyBrain.State.TELEGRAPH and second.state == EnemyBrain.State.TELEGRAPH, "both see same threshold crossing")
	_expect(_trace == ["decide:1001", "decide:1002", "plan:1001", "plan:1002", "move:1001", "move:1002", "execute:1001", "execute:1002"], "all decisions/plans precede moves in actor-id order")
	_expect(_context.snapshot.actors[0].actor_id == _party.states[0].actor_id and _context.snapshot.actors[1].actor_id == 1001, "frame sorted by actor id after reversed membership")
	_expect(_context.tick == tick_before + 1 and _damage.flush_calls == flush_before + 1, "one simulation tick/flush")
	var before := _view().position
	_view().call("_physics_process", 1.0 / 60.0)
	_expect(_view().position == before, "autonomous view callback cannot move twice")
	# Reactivating a pocket hero uses its controller position, never the stale view.
	_party.controllers[1].position = _origin + Vector2(0.6, 0.0)
	_party.swap_cooldown_left = 0
	frame = HeroInputFrame.new()
	frame.press(HeroInputFrame.Action.SWAP_2)
	_advance(frame)
	_expect(_context.snapshot.actor(_party.states[0].actor_id) == null, "pocket hero excluded from spatial frame")
	var sample := _context.snapshot.actor(_party.states[1].actor_id)
	_expect(sample != null and sample.position_m.is_equal_approx(_party.controllers[1].position), "swap captures activated controller after physical sync")
	_expect(_view().meters().is_equal_approx(_party.controllers[1].position), "activated pocket view catches up exactly once")


func _test_snapshot_values() -> void:
	_reset()
	var context := EnemyRoomContext.new()
	context.reset_room()
	context.begin_tick()
	var enemy := _enemies[0]
	enemy.prepare_tick(context)
	var proxy: Node2D = _preview.get("_hero_proxy")
	context.capture_actor(proxy, _party.active_state(), _origin, 0, 0.25, Vector2(1.0, 0.0), true)
	context.capture_actor(enemy, enemy.combat, enemy.meters(), enemy.level,
			enemy.definition.radius, Vector2.ZERO, true)
	# Duplicate capture cannot duplicate membership; sealing is also idempotent.
	context.capture_actor(enemy, enemy.combat, enemy.meters(), enemy.level, 0.3, Vector2.ZERO, true)
	var frame := context.finish_capture()
	_expect(frame == context.finish_capture() and frame.actors.size() == 2, "capture seals one sample per actor id")
	proxy.position += Vector2(100.0, 0.0) * enemy.pixels_per_meter
	(enemy.get("_brain") as EnemyBrain).state = EnemyBrain.State.CHASE
	enemy.decide_tick(context)
	enemy.plan_tick(context)
	var perception: EnemyPerception = enemy.get("_perception")
	var agent: NavigationAgent2D = enemy.get("_agent")
	_expect(perception.captured_position_m == _origin and is_equal_approx(perception.captured_distance_m, 3.0), "observation ignores adapter movement after capture")
	_expect(agent.target_position.is_equal_approx(enemy.get_parent().to_global(_origin * enemy.pixels_per_meter)), "navigation plans from captured goal")
	_expect(frame.actor(_party.active_state().actor_id).actual_velocity_mps == Vector2(1.0, 0.0), "frame carries velocity values in meters per second")
	proxy.position = _origin * enemy.pixels_per_meter
	proxy.hide()
	_advance()
	_expect(not _context.snapshot.actor(_party.active_state().actor_id).targetable and enemy.get("_perception").selected_actor_id == -1, "invisible target cannot be selected from frame")
	proxy.show()


func _test_repeated_phases_and_forced_motion() -> void:
	_reset()
	var enemy := _enemies[0]
	enemy.combat.statuses.apply(CombatTypes.Status.STUN)
	enemy.combat.apply_knockback(0.7, Vector2.RIGHT)
	enemy.combat.invulnerable_ticks = 5
	var before := enemy.meters()
	var offset := enemy.combat.knockback_offset()
	var knockback_ticks := enemy.combat.knockback_ticks
	var stun_ticks := enemy.combat.statuses.remaining_ticks[CombatTypes.Status.STUN]
	_advance()
	var after := enemy.meters()
	_expect(after.is_equal_approx(before + offset), "stunned live enemy keeps one forced movement step")
	_expect(_context.snapshot.actor(enemy.combat.actor_id) != null, "stunned live enemy remains a spatial sample")
	for i in 3:
		enemy.prepare_tick(_context)
		enemy.decide_tick(_context)
		enemy.plan_tick(_context)
		enemy.move_tick(_context)
		enemy.execute_tick(_context)
	_expect(enemy.meters().is_equal_approx(after), "repeated same-tick phases cannot move twice")
	_expect(enemy.combat.invulnerable_ticks == 4 and enemy.combat.knockback_ticks == knockback_ticks - 1 and enemy.combat.statuses.remaining_ticks[CombatTypes.Status.STUN] == stun_ticks - 1, "repeated phases cannot advance combat timers twice")
	_expect(enemy.actual_velocity_mps.is_equal_approx((after - before) * 60.0), "actual velocity uses measured displacement")
	var brain: EnemyBrain = enemy.get("_brain")
	enemy.combat.statuses.clear()
	brain.state = EnemyBrain.State.COOLDOWN
	brain.cooldown_ticks = 7
	_advance()
	enemy.decide_tick(_context)
	_expect(brain.cooldown_ticks == 6, "FSM cooldown decrements once")


func _test_preparation_death() -> void:
	_reset()
	var enemy := _enemies[0]
	enemy.combat.hp = 0.1
	enemy.combat.apply_knockback(0.7, Vector2.RIGHT)
	enemy.combat.statuses.apply(CombatTypes.Status.BURN, 1, _party.active_state().actor_id)
	enemy.combat.statuses.set("_dot_ticks", 1)
	var brain: EnemyBrain = enemy.get("_brain")
	brain.state = EnemyBrain.State.TELEGRAPH
	brain.telegraph_ticks = 1
	var before := enemy.position
	_advance()
	_expect(not enemy.combat.alive and _context.snapshot.actor(enemy.combat.actor_id) == null, "DoT death during preparation excluded from frame")
	_expect(enemy.position == before and enemy.actual_velocity_mps == Vector2.ZERO, "DoT death discards saved knockback")
	_expect(not enemy.get("_strike_pending") and brain.telegraph_ticks == 1, "DoT-dead source neither decides nor strikes")


func _test_fresh_geometry() -> void:
	_reset()
	for enemy: BasicEnemy in _enemies:
		enemy.combat.statuses.apply(CombatTypes.Status.STUN)
	var enemy := _enemies[0]
	var second := _enemies[1]
	enemy.position = (_origin + Vector2(4.0, 0.0)) * enemy.pixels_per_meter
	second.position = (_origin + Vector2(0.5, 0.0)) * second.pixels_per_meter
	# Establish server geometry on opposite sides of the query before moving this tick.
	for i in 2:
		await physics_frame
	_preview.call("_spawn_strike", _attack(), _origin, Vector2.ZERO, 0.45, 0.0, 3)
	enemy.combat.apply_knockback(3.7 * 7.0, Vector2.LEFT) # one step crosses into burst
	second.combat.apply_knockback(3.0 * 7.0, Vector2.RIGHT) # one step leaves burst
	_advance()
	_expect(enemy.combat.hp == 50.0, "fresh first-tick hero hit sees enemy moved INTO area")
	_expect(second.combat.hp == 60.0, "fresh first-tick hero hit rejects enemy moved OUT of area")
	var strike: Hitbox2D = _preview.get("_strikes")[0].node
	var clock := strike.combat_tick
	var shape: CollisionShape2D = strike.get_child(0)
	strike.tick_current(shape.shape, shape.global_transform, strike.get_world_2d().direct_space_state, _context.tick)
	_expect(strike.combat_tick == clock and enemy.combat.hp == 50.0, "same simulation tick query/clock guarded")
	enemy.combat.knockback_ticks = 0
	second.combat.knockback_ticks = 0
	_advance()
	_expect(enemy.combat.hp == 50.0, "HitRegistry preserves one hit across lifetime")
	_advance()
	_expect((_preview.get("_strikes") as Array).is_empty() and (_preview.get("_registry") as HitRegistry).attack_count() == 0, "strike lifetime/end_attack clear registry")
	# An already-active burst must also use this tick's geometry after the next move.
	_reset()
	for body: BasicEnemy in _enemies:
		body.combat.statuses.apply(CombatTypes.Status.STUN)
	_preview.call("_spawn_strike", _attack(), _origin, Vector2.ZERO, 0.45, 0.0, 3)
	_advance()
	_expect(enemy.combat.hp == 60.0, "existing burst starts with target outside")
	enemy.combat.apply_knockback(3.0 * 7.0, Vector2.LEFT)
	_advance()
	_expect(enemy.combat.hp == 50.0, "existing burst sees target moved into current geometry")


func _test_source_guards_and_reentry() -> void:
	_reset()
	var first := _enemies[0]
	var second := _enemies[1]
	for enemy: BasicEnemy in _enemies:
		enemy.position = (_origin + Vector2(0.8, 0.0)) * enemy.pixels_per_meter
		var brain: EnemyBrain = enemy.get("_brain")
		brain.state = EnemyBrain.State.TELEGRAPH
		brain.telegraph_ticks = 1
	var observer := HitObserver.new()
	observer.callback = func(_source: CombatantState, _target: CombatantState) -> void:
		_expect(first.state == EnemyBrain.State.TELEGRAPH, "damage callback still sees TELEGRAPH")
		first.execute_tick(_context)
		second.combat.statuses.apply(CombatTypes.Status.STUN)
		_party.active_state().statuses.apply(CombatTypes.Status.STUN)
	_add_observer(first.combat, observer, &"cancel_later")
	_preview.call("_spawn_strike", _attack(), _origin, Vector2.ZERO, 2.0, 0.0, 2)
	_advance()
	_expect(observer.calls == 1, "pending strike consumed before callback reentry")
	_expect(second.state == EnemyBrain.State.COOLDOWN and not second.get("_strike_pending") and (second.get("_brain") as EnemyBrain).cooldown_ticks == roundi(second.definition.attack_cooldown * 60), "later disabled striker consumes attempt and full cooldown")
	_expect(_party.active_state().hp == 1000.0 - first.definition.attack_damage, "only the first enemy delivers damage")
	_expect(first.combat.hp == 60.0 and second.combat.hp == 60.0, "disabled hero source cannot deliver later hero strikes")
	var hp := _party.active_state().hp
	first.execute_tick(_context)
	second.execute_tick(_context)
	_expect(_party.active_state().hp == hp, "cancelled/reentered strike cannot replay")
	second.combat.statuses.clear()
	_advance()
	_expect(_party.active_state().hp == hp and second.state == EnemyBrain.State.COOLDOWN, "cancelled strike cannot replay on a later tick")
	first.combat.modifiers.clear()
	observer.callback = Callable()
	# Within one multi-victim query, callback disabling the source prevents later delivery.
	_reset()
	for enemy: BasicEnemy in _enemies:
		enemy.combat.statuses.apply(CombatTypes.Status.STUN)
		enemy.position = (_origin + Vector2(0.2, 0.0)) * enemy.pixels_per_meter
	observer = HitObserver.new()
	observer.callback = func(source: CombatantState, _target: CombatantState) -> void:
		source.statuses.apply(CombatTypes.Status.STUN)
	_add_observer(_party.active_state(), observer, &"cancel_multihit")
	_preview.call("_spawn_strike", _attack(), _origin, Vector2.ZERO, 1.0, 0.0, 1)
	_advance()
	_expect(observer.victim_ids == [1001] and _enemies[1].combat.hp == 60.0, "victims ordered by id and source rechecked between hits")
	_party.active_state().modifiers.clear()
	observer.callback = Callable()
	# Death between victims has the same per-delivery guard as stun.
	_reset()
	for enemy: BasicEnemy in _enemies:
		enemy.combat.statuses.apply(CombatTypes.Status.STUN)
		enemy.position = (_origin + Vector2(0.2, 0.0)) * enemy.pixels_per_meter
	var dead_source := _party.active_state()
	observer = HitObserver.new()
	observer.callback = func(source: CombatantState, _target: CombatantState) -> void:
		source.alive = false
		source.hp = 0.0
	_add_observer(dead_source, observer, &"death_multihit")
	_preview.call("_spawn_strike", _attack(), _origin, Vector2.ZERO, 1.0, 0.0, 1)
	_advance()
	_expect(observer.victim_ids == [1001] and _enemies[1].combat.hp == 60.0, "dead source cannot deliver remaining victims")
	dead_source.modifiers.clear()
	observer.callback = Callable()
	# A mutable shared proxy must not redirect a decided strike to a new hero id.
	_reset()
	for enemy: BasicEnemy in _enemies:
		enemy.position = (_origin + Vector2(0.8, 0.0)) * enemy.pixels_per_meter
		var brain: EnemyBrain = enemy.get("_brain")
		brain.state = EnemyBrain.State.TELEGRAPH
		brain.telegraph_ticks = 1
	observer = HitObserver.new()
	observer.callback = func(_source: CombatantState, _target: CombatantState) -> void:
		_party.request_swap_to(1)
	_add_observer(first.combat, observer, &"swap_in_callback")
	_advance()
	_expect(_party.active_index() == 1 and _party.states[1].hp == 1000.0, "same-tick target id cannot be replaced by swapped proxy state")
	first.combat.modifiers.clear()
	observer.callback = Callable()
	# An earlier enemy callback can kill a later prepared source as well as stun it.
	_reset()
	for enemy: BasicEnemy in _enemies:
		enemy.position = (_origin + Vector2(0.8, 0.0)) * enemy.pixels_per_meter
		var brain: EnemyBrain = enemy.get("_brain")
		brain.state = EnemyBrain.State.TELEGRAPH
		brain.telegraph_ticks = 1
	observer = HitObserver.new()
	observer.callback = func(_source: CombatantState, _target: CombatantState) -> void:
		second.combat.alive = false
		second.combat.hp = 0.0
	_add_observer(first.combat, observer, &"kill_later")
	_advance()
	_expect(_party.active_state().hp == 1000.0 - first.definition.attack_damage and second.state == EnemyBrain.State.COOLDOWN, "dead later enemy source consumes strike without damage")
	first.combat.modifiers.clear()
	observer.callback = Callable()
	_reset()
	_party.active_state().alive = false
	for enemy: BasicEnemy in _enemies:
		enemy.combat.statuses.apply(CombatTypes.Status.STUN)
		enemy.position = _origin * enemy.pixels_per_meter
	_preview.call("_spawn_strike", _attack(), _origin, Vector2.ZERO, 1.0, 0.0, 1)
	_advance()
	_expect(_enemies[0].combat.hp == 60.0 and _enemies[1].combat.hp == 60.0, "dead hero source cannot deliver existing strikes")


func _test_room_boundary() -> void:
	_reset()
	var old_frame: EnemyRoomSnapshot
	var old_epoch := _context.epoch
	var old_tick := _context.tick
	var old_ids := [_enemies[0].combat.actor_id, _enemies[1].combat.actor_id]
	var first := _enemies[0]
	first.position = (_origin + Vector2(0.8, 0.0)) * first.pixels_per_meter
	var brain: EnemyBrain = first.get("_brain")
	brain.state = EnemyBrain.State.TELEGRAPH
	brain.telegraph_ticks = 1
	_enemies[1].combat.statuses.apply(CombatTypes.Status.STUN)
	var observer := HitObserver.new()
	var dungeon: DungeonData = _preview.get("_dungeon")
	var next: RoomData = dungeon.rooms[1]
	observer.callback = func(_source: CombatantState, _target: CombatantState) -> void:
		var room_before: RoomData = _preview.get("_room")
		_preview.call("_show_room", next)
		_expect(_context.epoch == old_epoch and _preview.get("_room") == room_before, "callback room change deferred through tick")
		_preview.call("_physics_process", 1.0 / 60.0)
		_expect(_context.tick == old_tick + 1, "owner rejects callback reentry")
	_add_observer(first.combat, observer, &"change_room")
	var flush_before := _damage.flush_calls
	# Retain the old captured frame from the actual callback before reset invalidates it.
	_advance()
	old_frame = first.get("_phase_frame")
	_expect(observer.calls == 1 and _context.epoch == old_epoch + 1, "pending room activates once at post-flush boundary")
	_expect(_context.tick == old_tick + 1 and _damage.flush_calls == flush_before + 1, "transition tick flushes exactly once")
	_expect(not _context.is_current(old_frame) and _context.snapshot == null, "room activation invalidates old snapshot")
	for id: int in old_ids:
		_expect(_context.resolve_actor(id, old_frame) == null, "old room actor cannot resolve")
	var before := first.position
	first.move_tick(_context)
	first.execute_tick(_context)
	_expect(first.position == before, "old phase work cannot move/strike after epoch change")
	first.combat.modifiers.clear()
	observer.callback = Callable()
	var view := _view()
	var proxy: Node2D = _preview.get("_hero_proxy")
	_expect(proxy.position.is_equal_approx(view.position), "entry snaps proxy before first new-room observation")
	# New membership is owned by preview; keep cleanup away from queued old nodes.
	_enemies = _preview.get("_enemies")
	_advance()
	_expect(_context.tick == old_tick + 2 and _context.epoch == old_epoch + 1, "simulation tick stays monotonic across room epochs")
	var sample := _context.snapshot.actor(_party.active_state().actor_id)
	_expect(sample != null and sample.position_m.is_equal_approx(_view().meters()), "first new-room frame uses new entry geometry")


func _attack() -> AttackDefinition:
	var attack := AttackDefinition.new()
	attack.id = &"r2_test"
	attack.base_damage = 10.0
	attack.poise_damage = 0.0
	return attack


func _add_observer(state: CombatantState, observer: HitObserver, id: StringName) -> void:
	var modifier := ModifierDefinition.new()
	modifier.id = id
	modifier.after_damage_handler = observer
	state.modifiers.add(modifier)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures += 1
		printerr(message)
