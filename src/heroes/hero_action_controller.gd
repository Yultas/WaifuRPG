class_name HeroActionController
extends RefCounted
## Fixed-tick combat controller for one hero. Owns a world position in meters and
## turns intents (request_attack/request_skill/request_dash/move_intent) into action
## states; everything advances in whole ticks, never scaled by frame delta.
##
## Damage delivery is deliberately not done here: attack_fired/skill_fired expose the
## AttackDefinition, origin and direction so a future Hitbox2D/DamageSystem
## integration (or a test) resolves the actual hits through the shared damage API.
## Movement is allowed during attack recovery and skill cast; the dash overrides
## movement and can be started from IDLE or ATTACKING (dash-cancel of the recovery).
## Knockback is forced displacement: while it runs it overrides intent movement,
## but never a running dash (dash i-frames already prevent new knockbacks mid-dash,
## and a knockback in flight when a dash starts keeps carrying the hero on top of
## the dash step). Like the pocket dash carry-over, knockback also displaces a
## benched hero; the authoritative position absorbs it and the view re-clamps it
## against walls through move_and_slide.

signal attack_fired(attack: AttackDefinition, origin: Vector2, direction: Vector2)
signal skill_fired(attack: AttackDefinition, origin: Vector2, direction: Vector2)

var state: HeroCombatState
var position := Vector2.ZERO
var facing := Vector2.DOWN
var move_intent := Vector2.ZERO


func setup(state_value: HeroCombatState, start_position: Vector2 = Vector2.ZERO) -> void:
	state = state_value
	position = start_position


## Advances one fixed tick. `active` is false for pocket heroes: their state still
## ticks (cooldowns, statuses, i-frames) and a running dash still displaces them,
## but intent movement and actions do not run.
func tick(active: bool, damage_system: DamageSystem) -> void:
	var was_dashing := state.alive and state.action == HeroCombatState.Action.DASHING
	var was_skilling := active and state.alive and state.action == HeroCombatState.Action.SKILLING
	# Read the offset before state.tick() decrements knockback_ticks: the knockback
	# belongs to this tick, so exactly knockback_ticks displacements are applied.
	var knockback := state.knockback_offset() if state.alive else Vector2.ZERO
	state.tick(damage_system)
	if not state.alive:
		return
	if not knockback.is_zero_approx():
		# Forced displacement; runs for pocket heroes too (see the class doc).
		position += knockback
	if was_dashing:
		# The tick that exhausts the dash still carries the hero the final step.
		# This also runs for pocket heroes: a dash survives a swap and keeps
		# displacing the benched hero, so no dash distance is lost on swap.
		position += state.dash_direction \
				* (state.hero_definition.dash_distance / float(state.dash_ticks()))
	if not active:
		return
	if knockback.is_zero_approx() and not was_dashing and state.can_act() \
			and move_intent != Vector2.ZERO:
		facing = move_intent.normalized()
		position += facing * state.hero_definition.speed \
				/ float(state.modifiers.ticks_per_second) * state.movement_multiplier()
	if was_skilling and state.alive and state.action == HeroCombatState.Action.IDLE:
		state.finish_skill()
		skill_fired.emit(state.hero_definition.skill, position, facing)


## Manual attack: fires immediately, then the recovery gates the next press.
func request_attack() -> bool:
	if state.action != HeroCombatState.Action.IDLE or not state.can_act():
		return false
	state.start_attack()
	attack_fired.emit(state.hero_definition.attack, position, facing)
	return true


func request_skill() -> bool:
	if state.action != HeroCombatState.Action.IDLE or state.skill_cooldown_left > 0 \
			or not state.can_act():
		return false
	state.start_skill()
	return true


func request_dash() -> bool:
	if state.dash_cooldown_left > 0 or not state.can_act():
		return false
	if state.action != HeroCombatState.Action.IDLE \
			and state.action != HeroCombatState.Action.ATTACKING:
		return false
	state.dash_direction = move_intent.normalized() if move_intent != Vector2.ZERO else facing
	state.start_dash()
	facing = state.dash_direction
	return true
