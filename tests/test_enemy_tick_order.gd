extends SceneTree
## Uses only baseline APIs: this regression also runs on the pre-R2 checkout.
## One input tick crosses melee range; the enemy must see the synchronized body now.

const PREVIEW = preload("res://scenes/debug/dungeon_preview.tscn")

var _failures := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var preview: Node2D = PREVIEW.instantiate()
	root.add_child(preview)
	for i in 5:
		await physics_frame
	preview.set_physics_process(false)
	var input_node: HeroInputNode = preview.get("_input_node")
	input_node.set_physics_process(false)
	var views: Array = preview.get("_views")
	for view: CombatHeroView in views:
		view.set_physics_process(false)
	var party: PartyController = preview.get("_party")
	var hero: CombatHeroView = views[party.active_index()]
	var map: RoomMap = preview.get("_room").map
	var origin := (Vector2(map.center) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE
	party.active_controller().position = origin
	hero.position = origin * hero.pixels_per_meter
	hero.call("_physics_process", 1.0 / 60.0)
	var enemies: Array = preview.get("_enemies")
	var enemy: BasicEnemy = enemies[0]
	for other: BasicEnemy in enemies:
		other.combat.statuses.apply(CombatTypes.Status.STUN, 1, -1)
	enemy.combat.statuses.clear()
	enemy.definition = enemy.definition.duplicate()
	enemy.definition.speed = 0.0
	enemy.position = (origin + Vector2(enemy.definition.attack_range + 0.04, 0.0)) * enemy.pixels_per_meter
	var brain = enemy.get("_brain")
	brain.reset()
	enemy.tick() # IDLE -> CHASE without displacement.
	var frame := HeroInputFrame.new()
	frame.move = Vector2.RIGHT
	preview.call("_on_hero_input_frame", frame)
	preview.call("_physics_process", 1.0 / 60.0)
	# Autonomous views used to run here, after the enemy had already observed.
	hero.call("_physics_process", 1.0 / 60.0)
	if enemy.state != BasicEnemy.State.TELEGRAPH:
		_failures += 1
		printerr("fresh input/proxy: expected TELEGRAPH on threshold-crossing tick, got %s (stale observation)" % enemy.state)
	if not hero.position.is_equal_approx(party.active_controller().position * hero.pixels_per_meter):
		_failures += 1
		printerr("fresh input/proxy: physical body is not synchronized")
	preview.queue_free()
	await process_frame
	call_deferred("_finish")


func _finish() -> void:
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures else 0)
