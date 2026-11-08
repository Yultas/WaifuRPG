class_name DamageCalculator
extends RefCounted
## Pure numeric damage pipeline. It has no scene, time, random, or rendering dependencies.


static func resolve_into(request: DamageRequest, result: DamageResult) -> void:
	var base_damage: float = maxf(0.0, request.base_damage + request.flat_bonus)
	var outgoing: float = base_damage * maxf(0.0, 1.0 + request.outgoing_additive)
	outgoing *= maxf(0.0, request.outgoing_multiplier)
	var incoming: float = outgoing * maxf(0.0, 1.0 + request.incoming_additive)
	result.damage = incoming * clampf(request.mitigation, 0.0, 2.0)
	result.poise_damage = maxf(0.0, request.poise_damage)
	result.damage_type = request.damage_type
