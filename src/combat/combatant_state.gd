class_name CombatantState
extends RefCounted
## Runtime combat state, independent from the visual Node representing the combatant.


var actor_id := -1
## Fixed knockback length: every knockback covers its full distance over this time.
const KNOCKBACK_DURATION_SECONDS := 0.12

var faction: CombatTypes.Faction = CombatTypes.Faction.HERO
var definition: CombatantDefinition
var modifiers := ModifierSet.new()
var statuses := StatusSet.new()
var hp := 10.0
var poise := 100.0
var alive := true
var invulnerable_ticks := 0
var hitstop_ticks := 0
var ticks_since_poise_damage := 0
## Remaining combat ticks of knockback movement; 0 means no active knockback.
var knockback_ticks := 0
## Displacement applied by controllers per combat tick while knockback_ticks > 0, in meters.
var knockback_per_tick := Vector2.ZERO


func configure(definition_value: CombatantDefinition, id_value: int,
		faction_value: CombatTypes.Faction, status_config: StatusConfig,
		ticks_per_second: int = 60) -> void:
	definition = definition_value
	actor_id = id_value
	faction = faction_value
	modifiers.ticks_per_second = ticks_per_second
	modifiers.instances.clear()
	modifiers.conditional.clear()
	modifiers.stats.reset()
	modifiers.stats_dirty = true
	statuses.configure(status_config, ticks_per_second)
	modifiers.stats.base_max_hp = definition.max_hp
	modifiers.stats.base_max_poise = definition.max_poise
	modifiers.stats.base_defense[CombatTypes.DamageType.PHYSICAL] = definition.physical_defense
	modifiers.stats.base_defense[CombatTypes.DamageType.MAGICAL] = definition.magical_defense
	modifiers.stats_dirty = true
	modifiers.rebuild()
	hp = modifiers.stats.max_hp
	poise = modifiers.stats.max_poise
	alive = true
	invulnerable_ticks = 0
	hitstop_ticks = 0
	ticks_since_poise_damage = 0
	knockback_ticks = 0
	knockback_per_tick = Vector2.ZERO


func tick(damage_system: DamageSystem) -> void:
	if not alive:
		return
	modifiers.tick()
	statuses.tick(self, damage_system)
	invulnerable_ticks = maxi(0, invulnerable_ticks - 1)
	hitstop_ticks = maxi(0, hitstop_ticks - 1)
	knockback_ticks = maxi(0, knockback_ticks - 1)
	ticks_since_poise_damage += 1
	var stats := modifiers.get_stats()
	var delay_ticks := roundi(definition.poise_regen_delay * modifiers.ticks_per_second)
	if ticks_since_poise_damage >= delay_ticks and not statuses.has(CombatTypes.Status.STUN):
		poise = minf(stats.max_poise, poise + definition.poise_regen_per_second / modifiers.ticks_per_second)
	hp = minf(hp, stats.max_hp)
	poise = minf(poise, stats.max_poise)


func apply_result(result: DamageResult) -> void:
	result.actual_damage = 0.0
	result.target_died = false
	result.staggered = false
	result.prevented = not alive or invulnerable_ticks > 0
	if result.prevented:
		return
	result.actual_damage = minf(hp, maxf(0.0, result.damage))
	hp = maxf(0.0, hp - result.actual_damage)
	ticks_since_poise_damage = 0
	poise = maxf(0.0, poise - maxf(0.0, result.poise_damage))
	if hp <= 0.0:
		alive = false
		result.target_died = true
		statuses.clear()
		return
	if poise <= 0.0 and result.poise_damage > 0.0:
		poise = modifiers.get_stats().max_poise
		statuses.apply(CombatTypes.Status.STUN, 1, -1)
		result.staggered = true


func health_ratio() -> float:
	var maximum := modifiers.get_stats().max_hp
	return hp / maximum if maximum > 0.0 else 0.0


func can_act() -> bool:
	return alive and hitstop_ticks == 0 \
			and not statuses.has(CombatTypes.Status.STUN) \
			and not statuses.has(CombatTypes.Status.FREEZE)


func movement_multiplier() -> float:
	return statuses.movement_multiplier() if can_act() else 0.0


func heal(amount: float) -> void:
	if alive:
		hp = minf(modifiers.get_stats().max_hp, hp + maxf(0.0, amount))


## Starts a knockback of `distance` meters along `direction` (need not be normalized).
## The full distance is covered over the fixed KNOCKBACK_DURATION_SECONDS; the resulting
## per-tick displacement is exposed via knockback_offset() for controllers to apply.
## Ignored for dead combatants, zero distance or a zero direction.
func apply_knockback(distance: float, direction: Vector2) -> void:
	if not alive or distance <= 0.0 or direction.is_zero_approx():
		return
	var ticks := maxi(1, roundi(KNOCKBACK_DURATION_SECONDS * modifiers.ticks_per_second))
	knockback_ticks = ticks
	knockback_per_tick = direction.normalized() * (distance / ticks)


## Meters to displace this combat tick; zero when no knockback is active.
func knockback_offset() -> Vector2:
	return knockback_per_tick if knockback_ticks > 0 else Vector2.ZERO
