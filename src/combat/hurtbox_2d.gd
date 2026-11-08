class_name Hurtbox2D
extends Area2D
## Passive damage-receiving area of a combatant. Carries the owner's CombatantState (and so
## the actor_id and faction) but never holds HP itself. Lives on its own collision layer,
## separate from movement colliders and terrain (layers 0..2); it never monitors anything.

const LAYER_BIT := 1 << 3
const HITBOX_BIT := 1 << 4

var combatant: CombatantState


func _init() -> void:
	collision_layer = LAYER_BIT
	collision_mask = 0
	monitoring = false


func actor_id() -> int:
	return combatant.actor_id if combatant != null else -1
