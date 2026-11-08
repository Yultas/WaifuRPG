extends SceneTree
## Run: godot --headless --path . -s res://tests/test_camera.gd

const Preview := preload("res://scenes/debug/dungeon_preview.gd")

var _failures := 0


func _initialize() -> void:
	var room := Vector2(800, 600)
	var viewport := Vector2(1600, 900)
	_check(Vector2.ZERO, room, viewport, Vector2.ONE * 3.0, Vector2(800.0 / 3.0, 150))
	_check(room, room, viewport, Vector2.ONE * 3.0, Vector2(1600.0 / 3.0, 450))
	_check(room * 0.5, room, viewport, Vector2.ONE * 3.0, room * 0.5)
	_check(Vector2.ZERO, room, viewport, Vector2.ONE, room * 0.5)
	_check(Vector2(400, 1200), Vector2(400, 1200), viewport, Vector2.ONE, Vector2(200, 750))
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _check(target: Vector2, room: Vector2, viewport: Vector2, zoom: Vector2,
		expected: Vector2) -> void:
	var actual: Vector2 = Preview._clamp_camera_position(target, room, viewport, zoom)
	if not actual.is_equal_approx(expected):
		_failures += 1
		printerr("target %s, room %s, zoom %s: expected %s, got %s" % [
			target, room, zoom, expected, actual])
