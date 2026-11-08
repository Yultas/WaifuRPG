class_name AttackDefinition
extends Resource
## Static data for one attack. Cooldowns belong to the action using the attack.


@export var id: StringName
@export var damage_type: CombatTypes.DamageType = CombatTypes.DamageType.PHYSICAL
@export var base_damage := 0.0
@export var poise_damage := 0.0
@export var knockback_distance := 0.0 ## Meters pushed away from the attacker; 0 means no knockback.
@export_flags("Melee", "Projectile", "AoE", "DoT") var tags := 1
@export var hit_cooldown := 0.0 ## Min seconds between repeat hits on the same target; 0 means one hit per combat tick.
@export var max_hits_per_target := 1 ## <= 0 means unlimited repeat hits, still gated by hit_cooldown.
@export var status_applications: Array[StatusApplication] = []
