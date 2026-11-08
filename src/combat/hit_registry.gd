class_name HitRegistry
extends RefCounted
## Repeat-hit rules for active attacks. Maps (attack_instance_id, target actor_id) to the
## number of hits delivered and the next combat tick on which a hit is allowed. Entries of a
## finished attack are dropped together with the attack; nothing accumulates over time.
## A recorded hit can be rolled back (rollback_hit) when damage delivery turns out prevented.


class HitRecord:
	extends RefCounted
	var hits := 0
	var next_allowed_tick := 0
	var prev_next_allowed_tick := 0


var _records: Dictionary[int, Dictionary] = {}


## Returns true when the hit is allowed and records it. `cooldown_ticks` is the minimum gap
## between hits on the same target, in combat ticks (values below 1 mean one hit per tick).
## `max_hits` <= 0 means unlimited hits, still gated by the cooldown.
func register_hit(attack_instance_id: int, target_id: int, tick: int,
		cooldown_ticks: int, max_hits: int) -> bool:
	var targets: Dictionary = {}
	if _records.has(attack_instance_id):
		targets = _records[attack_instance_id]
	else:
		_records[attack_instance_id] = targets
	var record: HitRecord = targets.get(target_id)
	if record == null:
		record = HitRecord.new()
		targets[target_id] = record
	if tick < record.next_allowed_tick:
		return false
	if max_hits > 0 and record.hits >= max_hits:
		return false
	record.prev_next_allowed_tick = record.next_allowed_tick
	record.hits += 1
	record.next_allowed_tick = tick + maxi(1, cooldown_ticks)
	return true


## Reverts the last register_hit for the pair, e.g. when DamageSystem.deal reports the
## hit as prevented (target died or turned invulnerable before damage resolved). Restores
## the hit budget and the previous next_allowed_tick, so the attack can hit the target
## again later. Returns false when there is nothing to roll back.
func rollback_hit(attack_instance_id: int, target_id: int) -> bool:
	if not _records.has(attack_instance_id):
		return false
	var targets: Dictionary = _records[attack_instance_id]
	var record: HitRecord = targets.get(target_id)
	if record == null or record.hits <= 0:
		return false
	record.hits -= 1
	record.next_allowed_tick = record.prev_next_allowed_tick
	if record.hits == 0 and record.next_allowed_tick == 0:
		targets.erase(target_id)
		if targets.is_empty():
			_records.erase(attack_instance_id)
	return true


func hits_for(attack_instance_id: int, target_id: int) -> int:
	if not _records.has(attack_instance_id):
		return 0
	var targets: Dictionary = _records[attack_instance_id]
	var record: HitRecord = targets.get(target_id)
	return record.hits if record != null else 0


func clear_attack(attack_instance_id: int) -> void:
	_records.erase(attack_instance_id)


func clear_target(target_id: int) -> void:
	for attack_instance_id: int in _records:
		(_records[attack_instance_id] as Dictionary).erase(target_id)


func clear() -> void:
	_records.clear()


func attack_count() -> int:
	return _records.size()
