class_name ModifierOperation
extends Resource
## One data-driven stat operation. Additive stats sum; multipliers multiply.


@export var stat: CombatTypes.Stat = CombatTypes.Stat.FLAT_DAMAGE
@export var value := 0.0
@export_flags("Physical", "Magical") var damage_type_mask := 3
@export_flags("Melee", "Projectile", "AoE", "DoT") var required_attack_tags := 0
