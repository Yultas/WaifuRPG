class_name EnemyActorSample
extends RefCounted
## Value-only room-local meters, captured once before enemy decisions. Treat as read-only.

var actor_id := -1
var position_m := Vector2.ZERO
var level := 0
var radius_m := 0.0
var actual_velocity_mps := Vector2.ZERO
var alive := false
var targetable := false
var faction: CombatTypes.Faction = CombatTypes.Faction.ENEMY
