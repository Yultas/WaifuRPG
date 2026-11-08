extends SceneTree
## Run: godot --headless --path . -s res://tests/test_remote_hero_view.gd

var _failures := 0


func _initialize() -> void:
	var state := HeroCombatState.new()
	state.configure_hero(load("res://data/heroes/hero_default.tres"), 1, StatusConfig.new())
	var controller := HeroActionController.new()
	controller.setup(state)
	var view := RemoteHeroView.new()
	root.add_child(view)
	view.bind(state)
	view.apply_snapshot(Vector2(2.0, 3.0), Vector2.RIGHT, true)
	_expect(view.position == Vector2(2.0, 3.0) * WorldUnits.PIXELS_PER_METER,
		"remote: snapshot position was not applied in pixels")
	_expect(view.get_class() == "Node2D", "remote: replica is an authoritative physics body")
	_expect(view.find_children("*", "CollisionShape2D", true, false).is_empty(),
		"remote: replica contains gameplay collision")
	_expect(view.find_children("*", "Hurtbox2D", true, false).is_empty(),
		"remote: replica contains a hurtbox")
	controller.position = Vector2(9.0, 9.0)
	state.hp = 6.0
	await process_frame
	_expect(controller.position == Vector2(9.0, 9.0),
		"remote: view wrote back to the action controller")
	_expect(is_equal_approx(state.hp, 6.0), "remote: view changed authoritative HP")
	view.apply_snapshot(Vector2(4.0, 5.0), Vector2.UP, false)
	_expect(not view.visible, "remote: inactive hero remained visible")
	_expect(view.position == Vector2(4.0, 5.0) * WorldUnits.PIXELS_PER_METER,
		"remote: next snapshot did not replace the position")
	view.queue_free()
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
