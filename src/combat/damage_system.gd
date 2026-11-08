class_name DamageSystem
extends RefCounted
## Single entry point for direct hits and status damage. Host-side gameplay owns this.


const MAX_QUEUED_HITS := 64

var status_config := StatusConfig.new()
var ticks_per_second := 60
var hitstop_ticks := 2
var _request := DamageRequest.new()
var _status_attack := AttackDefinition.new()
var _sources: Dictionary[int, CombatantState] = {}
var _queued_hits: Array[Dictionary] = []
var _notifying_after_damage := false


func register_combatant(state: CombatantState) -> void:
	_sources[state.actor_id] = state


func unregister_combatant(actor_id: int) -> void:
	_sources.erase(actor_id)


## Bounded buffer for secondary hits requested by after_damage handlers.
## Returns false when the queue is full and the hit is dropped.
func queue_hit(attack: AttackDefinition, source: CombatantState, target: CombatantState,
		scale: float = 1.0) -> bool:
	if _queued_hits.size() >= MAX_QUEUED_HITS:
		return false
	_queued_hits.append({
		"attack": attack,
		"source": source,
		"target": target,
		"scale": scale,
	})
	return true


## Drains queued secondary hits. Each call processes at most MAX_QUEUED_HITS hits,
## so self-queuing handlers cannot spin forever inside one flush.
func flush() -> int:
	var processed := 0
	while not _queued_hits.is_empty() and processed < MAX_QUEUED_HITS:
		var entry: Dictionary = _queued_hits.pop_front()
		var result := DamageResult.new()
		deal(entry.attack, entry.source, entry.target, result, entry.scale)
		processed += 1
	return processed


func deal(attack: AttackDefinition, source: CombatantState, target: CombatantState,
		result: DamageResult, scale: float = 1.0,
		knockback_direction := Vector2.ZERO) -> void:
	result.reset()
	if _notifying_after_damage:
		# Called from an after_damage handler: defer instead of recursing.
		queue_hit(attack, source, target, scale)
		return
	if target == null or not target.alive or target.invulnerable_ticks > 0:
		result.prevented = true
		return
	if source == target or (source != null and source.faction == target.faction):
		result.prevented = true
		return
	_build_request(attack, source, target, scale)
	DamageCalculator.resolve_into(_request, result)
	target.apply_result(result)
	if result.prevented:
		return
	if attack.knockback_distance > 0.0 and not knockback_direction.is_zero_approx() \
			and attack.tags & CombatTypes.AttackTag.DOT == 0:
		target.apply_knockback(attack.knockback_distance, knockback_direction)
	if result.actual_damage > 0.0 and attack.tags & CombatTypes.AttackTag.DOT == 0:
		target.hitstop_ticks = maxi(target.hitstop_ticks, hitstop_ticks)
	if target.alive:
		var source_id := source.actor_id if source != null else -1
		for application: StatusApplication in attack.status_applications:
			target.statuses.apply(application.status, application.stacks, source_id)
	if result.actual_damage > 0.0:
		_notifying_after_damage = true
		if source != null:
			source.modifiers.notify_after_damage(source, target, result.actual_damage)
		target.modifiers.notify_after_damage(source, target, result.actual_damage)
		_notifying_after_damage = false


func deal_status(target: CombatantState, status: CombatTypes.Status,
		damage: float, source_id: int) -> void:
	_status_attack.id = "dot"
	_status_attack.base_damage = damage
	_status_attack.poise_damage = 0.0
	_status_attack.tags = CombatTypes.AttackTag.DOT
	_status_attack.knockback_distance = 0.0
	_status_attack.damage_type = CombatTypes.DamageType.MAGICAL \
			if status == CombatTypes.Status.BURN else CombatTypes.DamageType.PHYSICAL
	_status_attack.status_applications = []
	var result := DamageResult.new()
	deal(_status_attack, _sources.get(source_id), target, result)


func _build_request(attack: AttackDefinition, source: CombatantState,
		target: CombatantState, scale: float) -> void:
	_request.reset()
	_request.damage_type = attack.damage_type
	_request.base_damage = attack.base_damage * scale
	_request.poise_damage = attack.poise_damage
	if source != null:
		var source_stats := source.modifiers.get_stats()
		_request.flat_bonus += source_stats.flat_bonus[attack.damage_type]
		_request.outgoing_additive += source_stats.outgoing_additive[attack.damage_type]
		_request.outgoing_multiplier *= source_stats.outgoing_multiplier[attack.damage_type]
		source.modifiers.apply_conditional(_request, source, target, attack.tags)
	var target_stats := target.modifiers.get_stats()
	_request.incoming_additive += target_stats.incoming_additive[attack.damage_type]
	_request.mitigation = target_stats.mitigation[attack.damage_type]
	if attack.tags & CombatTypes.AttackTag.DOT == 0:
		_request.incoming_additive += target.statuses.stacks_of(CombatTypes.Status.BLEED) \
				* status_config.bleed_bonus_per_stack
	target.modifiers.apply_conditional(_request, source, target, attack.tags)
