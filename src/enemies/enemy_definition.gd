class_name EnemyDefinition
extends CombatantDefinition
## Balance parameters of one enemy type. Perception ranges, attack values and attack
## timings live here on top of CombatantDefinition (max_hp, defenses, poise regen).
## Meters and seconds only (see docs/conventions.md); pixels come from WorldUnits at
## presentation time. All values belong in .tres.

## Chase starts when the hero is closer than this, m.
@export var detection_range := 8.0
## The enemy stops and telegraphs when the hero is closer than this, m.
@export var attack_range := 1.5
@export var attack_damage := 12.0
@export var poise_damage := 6.0
## Meters the struck target is pushed away from the enemy.
@export var attack_knockback := 0.5
## Immobile windup before the hit lands, s. Converted to fixed combat ticks by BasicEnemy.
@export var telegraph_duration := 0.5
## Time between two attacks, s. Converted to fixed combat ticks by BasicEnemy.
@export var attack_cooldown := 1.5
