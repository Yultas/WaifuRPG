class_name CombatTypes
extends RefCounted
## Shared combat enums.


enum DamageType { PHYSICAL, MAGICAL }
enum Faction { HERO, ENEMY }
enum Stat { FLAT_DAMAGE, OUTGOING_ADDITIVE, OUTGOING_MULTIPLIER, INCOMING_ADDITIVE, DEFENSE, MAX_HP, MAX_POISE }
enum Status { NONE, BURN, POISON, CHILL, FREEZE, STUN, BLEED }
enum AttackTag { NONE = 0, MELEE = 1, PROJECTILE = 2, AOE = 4, DOT = 8 }
