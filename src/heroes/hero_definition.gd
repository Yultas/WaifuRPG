class_name HeroDefinition
extends CombatantDefinition
## Static data for one hero: attacks, recovery/cooldowns and dash parameters.
## Meters and seconds only (see docs/conventions.md); gameplay code converts them
## to fixed ticks. All balance values live in .tres files.


@export var attack: AttackDefinition
## Seconds between two manual attacks (no autoattack).
@export var attack_recovery := 0.35
@export var skill: AttackDefinition
## Seconds before a pressed skill fires; started cooldown ticks while the hero
## sits in the pocket. Swapping out before this elapses cancels the skill.
@export var skill_cooldown := 3.0
## Cast time of the skill in seconds. Prototype balance, not in the GDD.
@export var skill_duration := 0.3
## Dash distance in meters.
@export var dash_distance := 3.0
## Dash duration in seconds; i-frames cover the whole dash.
@export var dash_duration := 0.18
@export var dash_cooldown := 0.8
