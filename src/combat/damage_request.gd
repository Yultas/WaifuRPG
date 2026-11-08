class_name DamageRequest
extends RefCounted
## Numeric input for one damage calculation. Modifiers are aggregated by the caller.


var damage_type: CombatTypes.DamageType = CombatTypes.DamageType.PHYSICAL
var base_damage := 0.0
var flat_bonus := 0.0
## Sum of ordinary outgoing percentage modifiers: 0.25 means +25%.
var outgoing_additive := 0.0
## Product of special outgoing multipliers.
var outgoing_multiplier := 1.0
## Sum of incoming percentage modifiers on the target.
var incoming_additive := 0.0
## Damage multiplier after mitigation, from 0 (immune) to 2 (maximum vulnerability).
var mitigation := 1.0
var poise_damage := 0.0


func reset() -> void:
	damage_type = CombatTypes.DamageType.PHYSICAL
	base_damage = 0.0
	flat_bonus = 0.0
	outgoing_additive = 0.0
	outgoing_multiplier = 1.0
	incoming_additive = 0.0
	mitigation = 1.0
	poise_damage = 0.0
