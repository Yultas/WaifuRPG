extends SceneTree
## Integration tests of the damage delivery layer on real Area2D overlaps:
## hitbox -> hurtbox detection, faction and self filtering, i-frame and dead checks through
## DamageSystem, one-shot/cooldown/max-hits repeat rules via HitRegistry on physics ticks,
## re-entry blocking, no budget consumption on prevented hits, registry cleanup on
## end_attack()/free, instant AoE shape queries, and the hitbox -> hurtbox knockback
## direction handoff to DamageSystem.
## Run: godot --headless --fixed-fps 60 --path . -s res://tests/test_hitboxes.gd
## (--fixed-fps makes physics run as fast as possible instead of in real time.)

const DAMAGE := 10.0

var _failures := 0
var _world: Node2D
var _damage_system: DamageSystem
var _registry: HitRegistry
var _attack: AttackDefinition
var _source: CombatantState
var _instance_id := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	_world = Node2D.new()
	root.add_child(_world)
	_damage_system = DamageSystem.new()
	_registry = HitRegistry.new()
	_attack = AttackDefinition.new()
	_attack.id = &"test_hit"
	_attack.base_damage = DAMAGE
	_attack.poise_damage = 0.0
	_source = _make_combatant(1, CombatTypes.Faction.HERO)
	await _test_one_shot_single_hit()
	await _test_knockback_direction_from_overlap()
	await _test_faction_and_self_filter()
	await _test_iframes_and_dead()
	await _test_prevented_hit_does_not_consume_budget()
	await _test_cooldown_repeat()
	await _test_max_hits()
	await _test_reentry_blocked()
	await _test_end_attack_clears_registry()
	await _test_free_clears_registry()
	await _test_aoe_query()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


## A one-shot attack overlapping for many physics ticks damages exactly once.
func _test_one_shot_single_hit() -> void:
	var target := _make_combatant(2, CombatTypes.Faction.ENEMY)
	var hurtbox := _make_hurtbox(target, Vector2.ZERO)
	var hitbox := _make_hitbox(Vector2.ZERO)
	await _frames(20)
	_expect_hp(target, 100.0 - DAMAGE, "one-shot: exactly one hit over 20 ticks")
	hitbox.queue_free()
	hurtbox.queue_free()
	await _frames(2)


## The knockback direction is the hitbox -> hurtbox direction: a hurtbox sitting to the
## right of the hitbox is pushed along +X at the fixed per-tick distance.
func _test_knockback_direction_from_overlap() -> void:
	var target := _make_combatant(14, CombatTypes.Faction.ENEMY)
	var hurtbox := _make_hurtbox(target, Vector2(24, 0))
	var attack := _duplicate_attack()
	attack.knockback_distance = 1.2
	var hitbox := _make_hitbox(Vector2.ZERO, attack)
	await _frames(5)
	var expected_ticks := maxi(1, roundi(CombatantState.KNOCKBACK_DURATION_SECONDS * 60))
	_expect_true(target.knockback_ticks > 0, "knockback: overlap produced no knockback")
	var offset := target.knockback_offset()
	_expect_true(is_equal_approx(offset.x, 1.2 / expected_ticks) and is_zero_approx(offset.y),
		"knockback: offset %s, expected +X %.6f m/tick" % [offset, 1.2 / expected_ticks])
	_expect_hp(target, 100.0 - DAMAGE, "knockback: hit still damaged the target")
	hitbox.queue_free()
	hurtbox.queue_free()
	await _frames(2)


## Same-faction, own, and ownerless hurtboxes take no damage.
func _test_faction_and_self_filter() -> void:
	var ally := _make_combatant(3, CombatTypes.Faction.HERO)
	var ally_hurtbox := _make_hurtbox(ally, Vector2.ZERO)
	var self_hurtbox := _make_hurtbox(_source, Vector2(50, 0))
	var stray := Hurtbox2D.new() ## no combatant attached
	var stray_shape := CollisionShape2D.new()
	stray_shape.shape = CircleShape2D.new()
	stray.add_child(stray_shape)
	stray.position = Vector2(-50, 0)
	_world.add_child(stray)
	var hitbox := _make_hitbox(Vector2.ZERO)
	await _frames(10)
	_expect_hp(ally, 100.0, "faction filter: ally untouched")
	_expect_hp(_source, 100.0, "self filter: source untouched")
	hitbox.queue_free()
	ally_hurtbox.queue_free()
	self_hurtbox.queue_free()
	stray.queue_free()
	await _frames(2)


## Invulnerable and dead targets are skipped without consuming the hit.
func _test_iframes_and_dead() -> void:
	var target := _make_combatant(4, CombatTypes.Faction.ENEMY)
	target.invulnerable_ticks = 100
	var hurtbox := _make_hurtbox(target, Vector2.ZERO)
	var hitbox := _make_hitbox(Vector2.ZERO)
	await _frames(10)
	_expect_hp(target, 100.0, "i-frames: no damage while invulnerable")
	target.invulnerable_ticks = 0
	await _frames(5)
	_expect_hp(target, 100.0 - DAMAGE, "i-frames: hit lands after they expire")
	target.alive = false
	await _frames(5)
	_expect_hp(target, 100.0 - DAMAGE, "dead: no further damage")
	hitbox.queue_free()
	hurtbox.queue_free()
	await _frames(2)


## A hit that DamageSystem reports as prevented must not consume the one-shot budget:
## the attack still lands exactly one real hit once the target can take damage.
func _test_prevented_hit_does_not_consume_budget() -> void:
	var target := _make_scripted_combatant(13, CombatTypes.Faction.ENEMY)
	target.invulnerable_on_apply = true
	var hurtbox := _make_hurtbox(target, Vector2.ZERO)
	var hitbox := _make_hitbox(Vector2.ZERO)
	await _frames(5)
	_expect_hp(target, 100.0, "prevented: no damage while hits are rejected")
	target.invulnerable_on_apply = false
	target.invulnerable_ticks = 0
	await _frames(5)
	_expect_hp(target, 100.0 - DAMAGE, "prevented: real hit still lands afterwards")
	_expect_true(_registry.hits_for(hitbox.attack_instance_id, target.actor_id) == 1,
			"prevented: only the delivered hit is counted")
	hitbox.queue_free()
	hurtbox.queue_free()
	await _frames(2)


## hit_cooldown 0.25 s at 60 ticks/s re-hits every 15 combat ticks while overlapping.
func _test_cooldown_repeat() -> void:
	var target := _make_combatant(5, CombatTypes.Faction.ENEMY)
	var hurtbox := _make_hurtbox(target, Vector2.ZERO)
	var attack := _duplicate_attack()
	attack.hit_cooldown = 0.25
	attack.max_hits_per_target = 0
	var hitbox := _make_hitbox(Vector2.ZERO, attack)
	await _frames(30)
	# Hits land on ticks 1 and 16; tick 31 is outside the window.
	_expect_hp(target, 100.0 - 2.0 * DAMAGE, "cooldown: exactly two hits in 30 ticks")
	hitbox.queue_free()
	hurtbox.queue_free()
	await _frames(2)


## max_hits_per_target caps repeats even with zero cooldown (one hit per tick).
func _test_max_hits() -> void:
	var target := _make_combatant(6, CombatTypes.Faction.ENEMY)
	var hurtbox := _make_hurtbox(target, Vector2.ZERO)
	var attack := _duplicate_attack()
	attack.hit_cooldown = 0.0
	attack.max_hits_per_target = 2
	var hitbox := _make_hitbox(Vector2.ZERO, attack)
	await _frames(20)
	_expect_hp(target, 100.0 - 2.0 * DAMAGE, "max hits: exactly two hits")
	hitbox.queue_free()
	hurtbox.queue_free()
	await _frames(2)


## Leaving and re-entering the area does not refresh a one-shot attack.
func _test_reentry_blocked() -> void:
	var target := _make_combatant(7, CombatTypes.Faction.ENEMY)
	var hurtbox := _make_hurtbox(target, Vector2.ZERO)
	var hitbox := _make_hitbox(Vector2.ZERO)
	await _frames(5)
	_expect_hp(target, 100.0 - DAMAGE, "reentry: first hit")
	hitbox.position = Vector2(500, 500)
	await _frames(3)
	hitbox.position = Vector2.ZERO
	await _frames(5)
	_expect_hp(target, 100.0 - DAMAGE, "reentry: no second hit after leaving and returning")
	hitbox.queue_free()
	hurtbox.queue_free()
	await _frames(2)


## end_attack() drops the registry entries: a new hitbox with the same instance id hits again.
func _test_end_attack_clears_registry() -> void:
	var target := _make_combatant(8, CombatTypes.Faction.ENEMY)
	var hurtbox := _make_hurtbox(target, Vector2.ZERO)
	var first := _make_hitbox(Vector2.ZERO)
	await _frames(5)
	_expect_hp(target, 100.0 - DAMAGE, "cleanup: first attack hit")
	var used_id := first.attack_instance_id
	first.end_attack()
	first.queue_free()
	_expect_true(_registry.attack_count() == 0, "cleanup: registry empty after end_attack")
	var second := _make_hitbox(Vector2.ZERO, _attack, used_id)
	await _frames(5)
	_expect_hp(target, 100.0 - 2.0 * DAMAGE, "cleanup: same instance id hits again")
	second.queue_free()
	hurtbox.queue_free()
	await _frames(2)


## Freeing the hitbox without end_attack() still clears its registry entries.
func _test_free_clears_registry() -> void:
	var target := _make_combatant(9, CombatTypes.Faction.ENEMY)
	var hurtbox := _make_hurtbox(target, Vector2.ZERO)
	var hitbox := _make_hitbox(Vector2.ZERO)
	await _frames(5)
	_expect_hp(target, 100.0 - DAMAGE, "free: hit delivered")
	hitbox.queue_free()
	await _frames(2)
	_expect_true(_registry.attack_count() == 0, "free: registry empty after queue_free")
	hurtbox.queue_free()
	await _frames(2)


## Instant AoE: one shape query damages both enemies in range, never the ally or the caster.
func _test_aoe_query() -> void:
	var enemy_a := _make_combatant(10, CombatTypes.Faction.ENEMY)
	var enemy_b := _make_combatant(11, CombatTypes.Faction.ENEMY)
	var ally := _make_combatant(12, CombatTypes.Faction.HERO)
	_make_hurtbox(enemy_a, Vector2(0, 0))
	_make_hurtbox(enemy_b, Vector2(80, 0))
	_make_hurtbox(ally, Vector2(0, 80))
	var probe := AoeProbe.new()
	probe.hitbox = _make_hitbox(Vector2(400, 400))
	probe.shape = CircleShape2D.new()
	(probe.shape as CircleShape2D).radius = 100.0
	probe.origin = Vector2(40, 0)
	_world.add_child(probe)
	while not probe.fired:
		await physics_frame
	_expect_true(probe.delivered == 2, "aoe: exactly two hits delivered, got %d" % probe.delivered)
	_expect_hp(enemy_a, 100.0 - DAMAGE, "aoe: enemy A damaged")
	_expect_hp(enemy_b, 100.0 - DAMAGE, "aoe: enemy B damaged")
	_expect_hp(ally, 100.0, "aoe: ally untouched")
	probe.hitbox.queue_free()
	await _frames(2)


func _make_combatant(id: int, faction: CombatTypes.Faction) -> CombatantState:
	var definition := CombatantDefinition.new()
	definition.max_hp = 100.0
	var state := CombatantState.new()
	state.configure(definition, id, faction, _damage_system.status_config)
	_damage_system.register_combatant(state)
	return state


func _make_scripted_combatant(id: int, faction: CombatTypes.Faction) -> ScriptedCombatantState:
	var definition := CombatantDefinition.new()
	definition.max_hp = 100.0
	var state := ScriptedCombatantState.new()
	state.configure(definition, id, faction, _damage_system.status_config)
	_damage_system.register_combatant(state)
	return state


func _make_hurtbox(target: CombatantState, position: Vector2) -> Hurtbox2D:
	var hurtbox := Hurtbox2D.new()
	hurtbox.combatant = target
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 16.0
	shape_node.shape = circle
	hurtbox.add_child(shape_node)
	hurtbox.position = position
	_world.add_child(hurtbox)
	return hurtbox


func _make_hitbox(position: Vector2, attack: AttackDefinition = _attack,
		instance_id := 0) -> Hitbox2D:
	var hitbox := Hitbox2D.new()
	hitbox.attack = attack
	hitbox.source = _source
	_instance_id += 1
	hitbox.attack_instance_id = instance_id if instance_id != 0 else _instance_id
	hitbox.damage_system = _damage_system
	hitbox.registry = _registry
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 16.0
	shape_node.shape = circle
	hitbox.add_child(shape_node)
	hitbox.position = position
	_world.add_child(hitbox)
	return hitbox


func _duplicate_attack() -> AttackDefinition:
	var attack := AttackDefinition.new()
	attack.id = _attack.id
	attack.base_damage = DAMAGE
	attack.poise_damage = 0.0
	return attack


func _frames(count: int) -> void:
	for i in count:
		await physics_frame
		for child: Node in _world.get_children():
			if child is Hitbox2D and not child.is_queued_for_deletion():
				child.tick()


func _expect_hp(target: CombatantState, expected: float, label: String) -> void:
	_expect_true(is_equal_approx(target.hp, expected),
			"%s: expected hp %.1f, got %.1f" % [label, expected, target.hp])


func _expect_true(condition: bool, label: String) -> void:
	if not condition:
		_failures += 1
		printerr(label)


class ScriptedCombatantState:
	extends CombatantState
	## Simulates a target whose protection flips on during damage resolution (e.g. it
	## died earlier in the same combat tick), so DamageSystem.deal reports prevented.
	var invulnerable_on_apply := false

	func apply_result(result: DamageResult) -> void:
		if invulnerable_on_apply:
			invulnerable_ticks = 1
		super.apply_result(result)


class AoeProbe:
	extends Node2D
	var hitbox: Hitbox2D
	var shape: Shape2D
	var origin := Vector2.ZERO
	var fired := false
	var delivered := 0

	func _physics_process(_delta: float) -> void:
		if fired:
			return
		fired = true
		delivered = hitbox.deal_aoe(shape, Transform2D(0.0, origin),
				get_world_2d().direct_space_state)
