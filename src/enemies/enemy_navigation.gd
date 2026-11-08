class_name EnemyNavigation
extends RefCounted
## Path-following adapter; the body owns the NavigationAgent2D and applies velocity.

var facing := Vector2.DOWN


## Returns velocity in the enemy parent's local pixels per second. Agent positions
## are global and are converted exactly once through the parent, as in BasicEnemy.
func chase_velocity(agent: NavigationAgent2D, target: Node2D, parent: Node,
		position: Vector2, speed_m_per_second: float, pixels_per_meter: float) -> Vector2:
	agent.target_position = target.global_position
	var next_local := Vector2.ZERO
	if parent == null:
		next_local = agent.get_next_path_position()
	else:
		next_local = parent.to_local(agent.get_next_path_position())
	var step := next_local - position
	if step.length() > 0.01:
		facing = step.normalized()
		return facing * speed_m_per_second * pixels_per_meter
	return Vector2.ZERO
