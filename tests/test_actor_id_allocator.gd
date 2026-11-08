extends SceneTree
## Run: godot --headless --path . -s res://tests/test_actor_id_allocator.gd

var _failures := 0


func _initialize() -> void:
	var ids := ActorIdAllocator.new()
	_expect(ids.allocate() == 1, "first id is not 1")
	_expect(ids.allocate() == 2, "second id is not 2")
	_expect(ids.allocate_block(3) == [3, 4, 5], "block is not contiguous")
	_expect(ids.allocate() == 6, "id was reused after a block")
	var custom := ActorIdAllocator.new(41)
	_expect(custom.allocate() == 41, "custom first id was ignored")
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
