class_name ModifierHandler
extends Resource
## Optional special behavior. Ordinary stat modifiers do not need a handler.


func after_damage(_source: CombatantState, _target: CombatantState, _actual_damage: float) -> void:
	pass
