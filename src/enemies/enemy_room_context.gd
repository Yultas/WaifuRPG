class_name EnemyRoomContext
extends RefCounted
## Owns room frame lifetime and adapter resolution, never combat state or AI timers.
## Tick is monotonic across rooms; resetting a room invalidates every old frame/id.

var tick := 0
var epoch := 0
var snapshot: EnemyRoomSnapshot
var _actors: Dictionary[int, Node2D] = {}
var _samples: Array[EnemyActorSample] = []


func reset_room() -> void:
	epoch += 1
	snapshot = null
	_actors.clear()
	_samples.clear()


func begin_tick() -> void:
	tick += 1
	snapshot = null
	_actors.clear()
	_samples.clear()


func capture_actor(adapter: Node2D, state: CombatantState, position_m: Vector2,
		level: int, radius_m: float, actual_velocity_mps: Vector2,
		targetable: bool) -> void:
	if state == null or not state.alive or _actors.has(state.actor_id):
		return
	var sample := EnemyActorSample.new()
	sample.actor_id = state.actor_id
	sample.position_m = position_m
	sample.level = level
	sample.radius_m = radius_m
	sample.actual_velocity_mps = actual_velocity_mps
	sample.alive = state.alive
	sample.targetable = targetable
	sample.faction = state.faction
	_samples.append(sample)
	_actors[state.actor_id] = adapter


func finish_capture() -> EnemyRoomSnapshot:
	if snapshot != null:
		return snapshot
	var frame := EnemyRoomSnapshot.new()
	frame.tick = tick
	frame.epoch = epoch
	frame.actors = _samples.duplicate()
	frame.actors.sort_custom(func(a: EnemyActorSample, b: EnemyActorSample) -> bool:
		return a.actor_id < b.actor_id)
	snapshot = frame
	return frame


func is_current(frame: EnemyRoomSnapshot) -> bool:
	return frame != null and frame == snapshot and frame.tick == tick and frame.epoch == epoch


func resolve_actor(actor_id: int, frame: EnemyRoomSnapshot) -> Node2D:
	if not is_current(frame):
		return null
	var adapter: Node2D = _actors.get(actor_id)
	return adapter if is_instance_valid(adapter) and not adapter.is_queued_for_deletion() else null
