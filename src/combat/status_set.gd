class_name StatusSet
extends RefCounted
## Fixed-size runtime status storage indexed by CombatTypes.Status.


const STATUS_COUNT := 7

var config := StatusConfig.new()
var ticks_per_second := 60
var stacks: Array[int] = [0, 0, 0, 0, 0, 0, 0]
var remaining_ticks: Array[int] = [0, 0, 0, 0, 0, 0, 0]
var source_ids: Array[int] = [-1, -1, -1, -1, -1, -1, -1]
var _dot_ticks := 0


func configure(config_value: StatusConfig, ticks_per_second_value: int) -> void:
	config = config_value
	ticks_per_second = ticks_per_second_value
	clear()


func has(status: CombatTypes.Status) -> bool:
	return stacks[status] > 0


func stacks_of(status: CombatTypes.Status) -> int:
	return stacks[status]


func apply(status: CombatTypes.Status, count: int = 1, source_id: int = -1) -> void:
	if status == CombatTypes.Status.NONE:
		return
	var maximum := _max_stacks(status)
	stacks[status] = mini(maximum, stacks[status] + maxi(1, count))
	source_ids[status] = source_id
	remaining_ticks[status] = roundi(_duration(status) * ticks_per_second)
	if status == CombatTypes.Status.CHILL and stacks[status] >= config.freeze_at_stacks:
		stacks[status] = 0
		remaining_ticks[status] = 0
		source_ids[status] = -1
		apply(CombatTypes.Status.FREEZE, 1, source_id)
	if status == CombatTypes.Status.BURN or status == CombatTypes.Status.POISON:
		if _dot_ticks <= 0:
			_dot_ticks = maxi(1, roundi(config.dot_interval * ticks_per_second))


func tick(owner: CombatantState, damage_system: DamageSystem) -> void:
	_dot_ticks = maxi(0, _dot_ticks - 1)
	if _dot_ticks == 0:
		_tick_dots(owner, damage_system)
	for status: int in range(1, STATUS_COUNT):
		if remaining_ticks[status] <= 0:
			continue
		remaining_ticks[status] -= 1
		if remaining_ticks[status] == 0:
			stacks[status] = 0
			source_ids[status] = -1


func movement_multiplier() -> float:
	return maxf(0.0, 1.0 - stacks[CombatTypes.Status.CHILL] * config.chill_slow_per_stack)


func clear() -> void:
	for status: int in STATUS_COUNT:
		stacks[status] = 0
		remaining_ticks[status] = 0
		source_ids[status] = -1
	_dot_ticks = 0


func _tick_dots(owner: CombatantState, damage_system: DamageSystem) -> void:
	var interval := maxf(0.01, config.dot_interval)
	if has(CombatTypes.Status.BURN):
		damage_system.deal_status(owner, CombatTypes.Status.BURN,
				config.burn_damage_per_second * stacks[CombatTypes.Status.BURN] * interval,
				source_ids[CombatTypes.Status.BURN])
	if has(CombatTypes.Status.POISON):
		damage_system.deal_status(owner, CombatTypes.Status.POISON,
				config.poison_damage_per_second * stacks[CombatTypes.Status.POISON] * interval,
				source_ids[CombatTypes.Status.POISON])
	_dot_ticks = maxi(1, roundi(interval * ticks_per_second))


func _max_stacks(status: CombatTypes.Status) -> int:
	match status:
		CombatTypes.Status.BURN:
			return config.burn_max_stacks
		CombatTypes.Status.POISON:
			return config.poison_max_stacks
		CombatTypes.Status.CHILL:
			return config.chill_max_stacks
		CombatTypes.Status.BLEED:
			return config.bleed_max_stacks
		_:
			return 1


func _duration(status: CombatTypes.Status) -> float:
	match status:
		CombatTypes.Status.BURN:
			return config.burn_duration
		CombatTypes.Status.POISON:
			return config.poison_duration
		CombatTypes.Status.CHILL:
			return config.chill_duration
		CombatTypes.Status.FREEZE:
			return config.freeze_duration
		CombatTypes.Status.STUN:
			return config.stun_duration
		CombatTypes.Status.BLEED:
			return config.bleed_duration
		_:
			return 0.0
