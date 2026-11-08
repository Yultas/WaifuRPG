class_name ModifierDefinition
extends Resource
## Shared static modifier data. Runtime stacks and duration live in ModifierInstance.


@export var id: StringName
@export var operations: Array[ModifierOperation] = []
@export var duration := 0.0
@export var max_stacks := 1
@export var adds_stack_on_reapply := true
@export var refreshes_duration := true
@export var priority := 0
@export var required_attack_tags := 0
@export var required_target_status: CombatTypes.Status = CombatTypes.Status.NONE
@export var target_hp_ratio_below := 1.0
@export var after_damage_handler: ModifierHandler


func is_conditional() -> bool:
	return required_attack_tags != 0 or required_target_status != CombatTypes.Status.NONE \
			or target_hp_ratio_below < 1.0
