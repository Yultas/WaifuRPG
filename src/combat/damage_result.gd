class_name DamageResult
extends RefCounted
## Reusable output of DamageCalculator. Applying it to health is a separate operation.


var damage_type: CombatTypes.DamageType = CombatTypes.DamageType.PHYSICAL
var damage := 0.0
var poise_damage := 0.0
var actual_damage := 0.0
var prevented := false
var target_died := false
var staggered := false


func reset() -> void:
	damage_type = CombatTypes.DamageType.PHYSICAL
	damage = 0.0
	poise_damage = 0.0
	actual_damage = 0.0
	prevented = false
	target_died = false
	staggered = false
