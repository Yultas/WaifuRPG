class_name CombatStats
extends RefCounted
## Aggregated stats read by damage delivery. Rebuilt only when modifiers change.


var base_max_hp := 10.0
var base_max_poise := 100.0
var base_defense: Array[float] = [0.0, 0.0]
var defense_constant := 0.06

var max_hp := 10.0
var max_poise := 100.0
var flat_bonus: Array[float] = [0.0, 0.0]
var outgoing_additive: Array[float] = [0.0, 0.0]
var outgoing_multiplier: Array[float] = [1.0, 1.0]
var incoming_additive: Array[float] = [0.0, 0.0]
var defense: Array[float] = [0.0, 0.0]
var mitigation: Array[float] = [1.0, 1.0]


func reset() -> void:
	max_hp = base_max_hp
	max_poise = base_max_poise
	for type: int in 2:
		flat_bonus[type] = 0.0
		outgoing_additive[type] = 0.0
		outgoing_multiplier[type] = 1.0
		incoming_additive[type] = 0.0
		defense[type] = base_defense[type]
		mitigation[type] = DefenseFormula.mitigation(defense[type], defense_constant)


func apply_operation(operation: ModifierOperation, stacks: int) -> void:
	match operation.stat:
		CombatTypes.Stat.MAX_HP:
			max_hp += operation.value * stacks
		CombatTypes.Stat.MAX_POISE:
			max_poise += operation.value * stacks
		_:
			for type: int in 2:
				if operation.damage_type_mask & (1 << type) == 0:
					continue
				_apply_to_type(operation, stacks, type)


func _apply_to_type(operation: ModifierOperation, stacks: int, type: int) -> void:
	match operation.stat:
		CombatTypes.Stat.FLAT_DAMAGE:
			flat_bonus[type] += operation.value * stacks
		CombatTypes.Stat.OUTGOING_ADDITIVE:
			outgoing_additive[type] += operation.value * stacks
		CombatTypes.Stat.OUTGOING_MULTIPLIER:
			outgoing_multiplier[type] *= pow(operation.value, stacks)
		CombatTypes.Stat.INCOMING_ADDITIVE:
			incoming_additive[type] += operation.value * stacks
		CombatTypes.Stat.DEFENSE:
			defense[type] += operation.value * stacks


static func apply_to_request(request: DamageRequest, operation: ModifierOperation, stacks: int) -> void:
	for type: int in 2:
		if type != request.damage_type or operation.damage_type_mask & (1 << type) == 0:
			continue
		match operation.stat:
			CombatTypes.Stat.FLAT_DAMAGE:
				request.flat_bonus += operation.value * stacks
			CombatTypes.Stat.OUTGOING_ADDITIVE:
				request.outgoing_additive += operation.value * stacks
			CombatTypes.Stat.OUTGOING_MULTIPLIER:
				request.outgoing_multiplier *= pow(operation.value, stacks)
			CombatTypes.Stat.INCOMING_ADDITIVE:
				request.incoming_additive += operation.value * stacks
