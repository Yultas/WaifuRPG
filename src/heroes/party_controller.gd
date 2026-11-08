class_name PartyController
extends RefCounted
## Fixed-tick controller of a 3-hero party. Exactly one hero is active; pocket
## heroes keep ticking, so their HP stays as-is while cooldowns and statuses run.
## Swap rules (docs/gdd/02_heroes.md): swap cooldown between swaps, no swap to a
## dead hero, swapping during a dash is allowed and never cancels the dash, and
## swapping during an unfinished skill cancels the skill.

signal hero_activated(index: int)
signal hero_deactivated(index: int)

const PARTY_SIZE := 3

var config: PartyConfig
var damage_system: DamageSystem
var states: Array[HeroCombatState] = []
var controllers: Array[HeroActionController] = []
var ticks_per_second := 60
var swap_cooldown_left := 0
var _active_index := 0


func setup(config_value: PartyConfig, damage_system_value: DamageSystem,
		status_config: StatusConfig, first_actor_id: int = 0,
		start_position: Vector2 = Vector2.ZERO, ticks_per_second_value: int = 60) -> void:
	if config_value == null or config_value.heroes.size() != PARTY_SIZE:
		push_error("PartyController.setup: config must define exactly %d heroes" % PARTY_SIZE)
		return
	config = config_value
	damage_system = damage_system_value
	ticks_per_second = ticks_per_second_value
	for index: int in PARTY_SIZE:
		var hero_state := HeroCombatState.new()
		hero_state.configure_hero(config.heroes[index], first_actor_id + index,
				status_config, ticks_per_second)
		damage_system.register_combatant(hero_state)
		var controller := HeroActionController.new()
		controller.setup(hero_state, start_position)
		states.append(hero_state)
		controllers.append(controller)


func active_index() -> int:
	return _active_index


func active_state() -> HeroCombatState:
	return states[_active_index]


func active_controller() -> HeroActionController:
	return controllers[_active_index]


func party_alive() -> bool:
	for hero_state: HeroCombatState in states:
		if hero_state.alive:
			return true
	return false


func apply_input(frame: HeroInputFrame) -> void:
	if frame == null:
		return
	controllers[_active_index].move_intent = frame.move
	if frame.is_pressed(HeroInputFrame.Action.ATTACK):
		request_attack()
	if frame.is_pressed(HeroInputFrame.Action.SKILL):
		request_skill()
	if frame.is_pressed(HeroInputFrame.Action.DASH):
		request_dash()
	if frame.is_pressed(HeroInputFrame.Action.SWAP_1):
		request_swap_to(0)
	if frame.is_pressed(HeroInputFrame.Action.SWAP_2):
		request_swap_to(1)
	if frame.is_pressed(HeroInputFrame.Action.SWAP_3):
		request_swap_to(2)
	if frame.is_pressed(HeroInputFrame.Action.SWAP_NEXT):
		request_swap_next()
	if frame.is_pressed(HeroInputFrame.Action.SWAP_PREV):
		request_swap_prev()


func set_move_intent(direction: Vector2) -> void:
	controllers[_active_index].move_intent = direction


func request_attack() -> bool:
	return controllers[_active_index].request_attack()


func request_skill() -> bool:
	return controllers[_active_index].request_skill()


func request_dash() -> bool:
	return controllers[_active_index].request_dash()


## One fixed tick for the whole party: swap cooldown first, then every hero state
## (pocket heroes included), with action logic only for the active controller.
func tick() -> void:
	swap_cooldown_left = maxi(0, swap_cooldown_left - 1)
	for index: int in controllers.size():
		controllers[index].tick(index == _active_index, damage_system)


func request_swap_to(index: int) -> bool:
	if index < 0 or index >= PARTY_SIZE or index == _active_index:
		return false
	if swap_cooldown_left > 0 or not states[index].alive:
		return false
	var current := states[_active_index]
	if current.action == HeroCombatState.Action.SKILLING:
		current.cancel_skill()
	# A dash is intentionally left running: the swapped-out hero keeps dashing in
	# the pocket until the dash ticks out.
	hero_deactivated.emit(_active_index)
	_active_index = index
	hero_activated.emit(index)
	swap_cooldown_left = maxi(1, roundi(config.swap_cooldown * float(ticks_per_second)))
	return true


## D-pad style cycling: next/prev alive hero, skipping dead ones.
func request_swap_next() -> bool:
	if swap_cooldown_left > 0:
		return false
	for step: int in range(1, PARTY_SIZE + 1):
		var index := (_active_index + step) % PARTY_SIZE
		if states[index].alive:
			return request_swap_to(index)
	return false


func request_swap_prev() -> bool:
	if swap_cooldown_left > 0:
		return false
	for step: int in range(1, PARTY_SIZE + 1):
		var index := posmod(_active_index - step, PARTY_SIZE)
		if states[index].alive:
			return request_swap_to(index)
	return false
