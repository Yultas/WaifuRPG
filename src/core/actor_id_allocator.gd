class_name ActorIdAllocator
extends RefCounted

## Monotonic run-scoped actor ids. Ids are never reused after room changes.

var _next_id := 1


func _init(first_id: int = 1) -> void:
	assert(first_id > 0, "ActorIdAllocator: first_id must be positive")
	_next_id = first_id


func allocate() -> int:
	var allocated := _next_id
	_next_id += 1
	return allocated


func allocate_block(count: int) -> Array[int]:
	assert(count > 0, "ActorIdAllocator: block size must be positive")
	var ids: Array[int] = []
	for _index: int in count:
		ids.append(allocate())
	return ids
