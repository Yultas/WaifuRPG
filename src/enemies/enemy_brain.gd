class_name EnemyBrain
extends RefCounted
## Per-instance melee state machine. Inputs use meters and fixed 60 Hz ticks;
## callers execute intents and retain ownership of movement and combat effects.

enum State { IDLE, CHASE, TELEGRAPH, COOLDOWN }
enum Intent { NONE, CHASE, STRIKE }

var state: State = State.IDLE
var telegraph_ticks := 0
var telegraph_total := 0
var cooldown_ticks := 0


## Clears action progress when entering a room.
func reset() -> void:
	state = State.IDLE
	telegraph_ticks = 0
	telegraph_total = 0
	cooldown_ticks = 0


## Advances once, or freezes all action progress when can_act is false.
## STRIKE must be executed and followed by finish_strike() before the next tick:
## observers of the strike still see TELEGRAPH, matching the combat callback order.
func tick(distance_m: float, detection_range_m: float, attack_range_m: float,
		windup_ticks: int, can_act := true) -> Intent:
	if not can_act:
		return Intent.NONE
	match state:
		State.IDLE:
			if distance_m <= detection_range_m:
				state = State.CHASE
		State.CHASE:
			if distance_m > detection_range_m:
				state = State.IDLE
			elif distance_m <= attack_range_m:
				_start_telegraph(windup_ticks)
			else:
				return Intent.CHASE
		State.TELEGRAPH:
			telegraph_ticks -= 1
			if telegraph_ticks <= 0:
				return Intent.STRIKE
		State.COOLDOWN:
			cooldown_ticks -= 1
			if cooldown_ticks <= 0:
				if distance_m <= attack_range_m:
					_start_telegraph(windup_ticks)
				elif distance_m <= detection_range_m:
					state = State.CHASE
				else:
					state = State.IDLE
	return Intent.NONE


## Starts the full recovery interval after a strike attempt, including a miss.
## Duration is sampled after executing the strike, as in the original enemy.
func finish_strike(recovery_ticks: int) -> void:
	cooldown_ticks = maxi(1, recovery_ticks)
	state = State.COOLDOWN


func _start_telegraph(windup_ticks: int) -> void:
	telegraph_total = maxi(1, windup_ticks)
	telegraph_ticks = telegraph_total
	state = State.TELEGRAPH
