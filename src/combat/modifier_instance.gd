class_name ModifierInstance
extends RefCounted
## Runtime state of one modifier on one combatant.


var definition: ModifierDefinition
var source_id := -1
var stacks := 1
var remaining_ticks := 0
var sequence := 0


func _init(definition_value: ModifierDefinition = null, ticks_per_second: int = 60) -> void:
	definition = definition_value
	if definition != null:
		remaining_ticks = roundi(definition.duration * ticks_per_second)
