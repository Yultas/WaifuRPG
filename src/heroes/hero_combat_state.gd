class_name HeroCombatState
extends CombatantState
## CombatantState extended with the hero action machine: manual attack recovery,
## skill cast + cooldown and dash (with i-frames). Cooldowns tick every fixed tick,
## also while the hero sits in the pocket (see docs/gdd/02_heroes.md).


enum Action { IDLE, ATTACKING, SKILLING, DASHING }

var hero_definition: HeroDefinition
var action := Action.IDLE
## Ticks left of the current action (attack recovery, skill cast or dash).
var action_ticks_left := 0
var skill_cooldown_left := 0
var dash_cooldown_left := 0
var dash_direction := Vector2.RIGHT


func configure_hero(definition_value: HeroDefinition, id_value: int,
		status_config: StatusConfig, ticks_per_second: int = 60) -> void:
	hero_definition = definition_value
	configure(definition_value, id_value, CombatTypes.Faction.HERO, status_config,
			ticks_per_second)


func tick(damage_system: DamageSystem) -> void:
	super.tick(damage_system)
	skill_cooldown_left = maxi(0, skill_cooldown_left - 1)
	dash_cooldown_left = maxi(0, dash_cooldown_left - 1)
	if not alive or action == Action.IDLE:
		return
	action_ticks_left = maxi(0, action_ticks_left - 1)
	if action_ticks_left == 0:
		action = Action.IDLE


func apply_result(result: DamageResult) -> void:
	super.apply_result(result)
	if not alive:
		action = Action.IDLE
		action_ticks_left = 0


func start_attack() -> void:
	action = Action.ATTACKING
	action_ticks_left = _seconds_to_ticks(hero_definition.attack_recovery)


func start_skill() -> void:
	action = Action.SKILLING
	action_ticks_left = _seconds_to_ticks(hero_definition.skill_duration)


func start_dash() -> void:
	action = Action.DASHING
	action_ticks_left = dash_ticks()
	# max: an external source may have granted longer i-frames; a dash must
	# never cut those short (it may only extend shorter ones to its own length).
	invulnerable_ticks = maxi(invulnerable_ticks, action_ticks_left)
	dash_cooldown_left = _seconds_to_ticks(hero_definition.dash_cooldown)


## Called when the skill cast completes: the cooldown starts on the fire tick.
func finish_skill() -> void:
	skill_cooldown_left = _seconds_to_ticks(hero_definition.skill_cooldown)


## Swap during an unfinished skill cancels it without consuming the cooldown.
func cancel_skill() -> void:
	if action == Action.SKILLING:
		action = Action.IDLE
		action_ticks_left = 0


func dash_ticks() -> int:
	return _seconds_to_ticks(hero_definition.dash_duration)


func _seconds_to_ticks(seconds: float) -> int:
	return maxi(1, roundi(seconds * modifiers.ticks_per_second))
