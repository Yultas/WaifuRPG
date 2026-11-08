extends Node2D
## Debug viewer for the dungeon generator and playable combat preview.
## WASD move (leave through a door to enter the next room), LMB attack, RMB skill,
## Space dash, 1/2/3 direct hero swap, F camera follows the hero, R new seed,
## B next biome, arrows jump through doors, Tab next room, O debug overlay,
## mouse wheel zoom.
## Command line (after `--`): --seed=N --biome=<id из data/biomes or path to a biome .tres>
## --room=N|boss|shop --overlay
## --follow --hero=x,y (start cell) --no-shake --screenshot=path.png (renders once, saves and quits).
##
## Combat: one shared DamageSystem + StatusConfig drive a PartyController with the 3
## heroes of data/heroes/party_default.tres (cooldowns keep ticking in the pocket) and
## every BasicEnemy spawned in the rooms. Hero attacks and skills fire transient
## Hitbox2D nodes resolved through a shared HitRegistry; heroes and enemies carry
## Hurtbox2D. The active hero view exposes its combat state through a HeroProxy that
## the enemies watch, so swaps retarget them.
## ActorIdAllocator hands a block of PARTY_SIZE ids to the party and one id per enemy.
## Ids stay unique across room changes and are assigned before DamageSystem registration.

const T := preload("res://src/dungeon/dungeon_types.gd")
const CONFIG := preload("res://data/dungeon/default_dungeon.tres")
const PARTY_TRES := preload("res://data/heroes/party_default.tres")
const ENEMY_TRES := preload("res://data/enemies/basic_enemy.tres")
const ENEMIES_PER_ROOM := 3
## Enemies spawn at least this many cells away from the hero's entry cell.
const MIN_SPAWN_DISTANCE := 4.0
const SHAKE_DURATION := 0.25
const ROOM_COLORS := {
	T.RoomType.START: Color(0.3, 0.8, 0.4),
	T.RoomType.COMBAT: Color(0.55, 0.55, 0.6),
	T.RoomType.SHOP: Color(0.95, 0.8, 0.2),
	T.RoomType.BOSS: Color(0.9, 0.25, 0.25),
}

var _seed := 1
var _biomes: Array[BiomeData] = BiomeData.load_all()
var _biome_index := 0
var _dungeon: DungeonData
var _room: RoomData
var _gen_msec := 0

var _status_config: StatusConfig
var _damage_system: DamageSystem
var _registry: HitRegistry
var _party: PartyController
var _input_node: HeroInputNode
var _views: Array[CombatHeroView] = []
var _hero_proxy: CombatHeroView.HeroProxy
var _enemies: Array[BasicEnemy] = []
var _attack_serial := 0
## Run-scoped ids are allocated for the party at startup and for each spawned enemy.
var _actor_ids := ActorIdAllocator.new()

var _renderer: RoomTileRenderer
var _overlay: RoomDebugOverlay
var _camera: Camera2D
var _follow := false
var _zoom_factor := 1.0
var _fit_zoom := 1.0
var _fit_position := Vector2.ZERO
var _info: Label
var _performance: Label
var _minimap: Minimap
var _no_shake := false
var _shake_left := 0.0
var _hero_hp_last: Array[float] = []

var _hud_names: Array[Label] = []
var _hud_bars: Array[ProgressBar] = []
var _hud_statuses: Array[Label] = []
var _hud_party: Label

## Transient hero attack/skill hitboxes, freed after a few physics ticks.
var _strikes: Array[Strike] = []
## Enemies playing their death shrink before being freed.
var _dying: Array[DyingEnemy] = []


class Strike:
	extends RefCounted
	var node: Hitbox2D
	var ticks := 0


class DyingEnemy:
	extends RefCounted
	var node: BasicEnemy
	var ticks := 0


class Minimap:
	extends Control
	var preview: Node

	func _draw() -> void:
		var dungeon: DungeonData = preview.get("_dungeon")
		var current: RoomData = preview.get("_room")
		if dungeon == null:
			return
		var cell := 26.0
		var lo := Vector2i.ZERO
		for room in dungeon.rooms:
			lo = Vector2i(mini(lo.x, room.grid_pos.x), mini(lo.y, room.grid_pos.y))
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))
		for room in dungeon.rooms:
			var center := Vector2(room.grid_pos - lo) * cell + Vector2(cell, cell)
			for dir in room.neighbors:
				draw_line(center, center + Vector2(T.DIR_VECTORS[dir]) * cell * 0.5, Color.WHITE, 2.0)
		for room in dungeon.rooms:
			var center := Vector2(room.grid_pos - lo) * cell + Vector2(cell, cell)
			var r := Rect2(center - Vector2.ONE * cell * 0.33, Vector2.ONE * cell * 0.66)
			draw_rect(r, ROOM_COLORS[room.type])
			if room == current:
				draw_rect(r.grow(3), Color.WHITE, false, 2.0)


func _ready() -> void:
	HeroInput.register()
	_status_config = StatusConfig.new()
	_damage_system = DamageSystem.new()
	_damage_system.status_config = _status_config
	_registry = HitRegistry.new()
	_party = PartyController.new()
	var party_ids := _actor_ids.allocate_block(PartyController.PARTY_SIZE)
	_party.setup(PARTY_TRES, _damage_system, _status_config, party_ids[0])
	_input_node = HeroInputNode.new()
	_input_node.process_physics_priority = -20
	_input_node.frame_ready.connect(_on_hero_input_frame)
	add_child(_input_node)

	_renderer = RoomTileRenderer.new()
	add_child(_renderer)
	_hero_proxy = CombatHeroView.HeroProxy.new()
	_hero_proxy.name = "HeroProxy"
	_renderer.actors.add_child(_hero_proxy)
	for index: int in PartyController.PARTY_SIZE:
		var view := CombatHeroView.new()
		_renderer.actors.add_child(view)
		view.bind(_party.states[index], _party.controllers[index])
		view.proxy = _hero_proxy
		_views.append(view)
		_party.controllers[index].attack_fired.connect(_on_attack_fired)
		_party.controllers[index].skill_fired.connect(_on_skill_fired)
		_hero_hp_last.append(_party.states[index].hp)
	_party.hero_activated.connect(_on_hero_activated)
	_party.hero_deactivated.connect(_on_hero_deactivated)
	_on_hero_activated(0)

	_overlay = RoomDebugOverlay.new()
	_overlay.visible = false
	add_child(_overlay)
	_camera = Camera2D.new()
	add_child(_camera)
	var ui := CanvasLayer.new()
	add_child(ui)
	_info = Label.new()
	_info.position = Vector2(12, 8)
	_info.add_theme_color_override("font_outline_color", Color.BLACK)
	_info.add_theme_constant_override("outline_size", 6)
	ui.add_child(_info)
	_minimap = Minimap.new()
	_minimap.preview = self
	_minimap.size = Vector2(260, 260)
	_minimap.position = Vector2(get_viewport_rect().size.x - 272, 12)
	ui.add_child(_minimap)
	_performance = Label.new()
	_performance.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_performance.offset_left = -140
	_performance.offset_top = -50
	_performance.offset_right = -12
	_performance.offset_bottom = -8
	_performance.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_performance.add_theme_color_override("font_outline_color", Color.BLACK)
	_performance.add_theme_constant_override("outline_size", 6)
	ui.add_child(_performance)
	_build_hud(ui)

	var room_arg := "0"
	var screenshot := ""
	var hero_cell := Vector2i(-1, -1)
	for arg in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		if arg.begins_with("--seed="):
			_seed = int(value)
		elif arg.begins_with("--biome=") and value.contains("://"):
			_biomes.append(load(value))
			_biome_index = _biomes.size() - 1
		elif arg.begins_with("--biome="):
			for i in _biomes.size():
				if _biomes[i].id == StringName(value):
					_biome_index = i
		elif arg.begins_with("--room="):
			room_arg = value
		elif arg == "--overlay":
			_overlay.visible = true
		elif arg == "--follow":
			_follow = true
		elif arg.begins_with("--hero="):
			hero_cell = Vector2i(int(value.get_slice(",", 0)), int(value.get_slice(",", 1)))
		elif arg == "--no-shake":
			_no_shake = true
		elif arg.begins_with("--screenshot="):
			screenshot = value
	_generate()
	var room_index := int(room_arg)
	if room_arg == "boss":
		room_index = _dungeon.boss_index
	elif room_arg == "shop":
		room_index = _dungeon.shop_index
	if room_index > 0 and room_index < _dungeon.rooms.size():
		_show_room(_dungeon.rooms[room_index])
	if _room.map.in_bounds(hero_cell):
		_place_party(hero_cell)
	if not screenshot.is_empty():
		for _frame in 3:
			await get_tree().physics_frame
		if DisplayServer.get_name() == "headless":
			# The dummy renderer has no framebuffer and never emits frame_post_draw;
			# without this branch the CLI would hang forever in headless mode.
			push_warning("--screenshot needs a real display; skipped in headless mode")
		else:
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(screenshot)
		get_tree().quit()


func _generate() -> void:
	var started := Time.get_ticks_msec()
	_dungeon = DungeonGenerator.generate(CONFIG, _seed, _biomes[_biome_index])
	_gen_msec = Time.get_ticks_msec() - started
	_show_room(_dungeon.rooms[_dungeon.start_index])


## Shows a room. With entry_dir the hero comes in through that door, else it starts at
## the room center.
func _show_room(room: RoomData, entry_dir := -1) -> void:
	_room = room
	var map := room.map
	_renderer.render(map, _dungeon.biome)
	_renderer.add_room_node(RoomCollision.build_2d(map, _renderer.local_pixels_per_meter,
			_dungeon.biome.tile_theme.cliff_face_depth))
	_renderer.add_room_node(RoomNavigation.build_2d(map, _renderer.local_pixels_per_meter))
	_clear_strikes()
	_clear_enemies()
	var start := map.center
	var door := map.door(entry_dir)
	if door != null:
		start = door.edge_cells[door.edge_cells.size() / 2] - T.DIR_VECTORS[entry_dir]
	_place_party(start)
	_spawn_enemies(map, start)
	_overlay.show_map(map, _dungeon.biome.tile_theme.cliff_face_depth)
	# Fit the room into the area left of the minimap and below the info text.
	var world := WorldUnits.cell_to_pixels(room.size)
	var view := get_viewport_rect().size
	var usable := Rect2(16, 84, view.x - 312, view.y - 100)
	_fit_zoom = minf(usable.size.x / world.x, usable.size.y / world.y)
	_fit_position = world * 0.5 - (usable.get_center() - view * 0.5) / _fit_zoom
	_update_camera()
	_update_info()


## Snaps every hero (active and pocket) to the same entry cell; the party then walks
## out of the shared spot on its own.
func _place_party(start: Vector2i) -> void:
	for view: CombatHeroView in _views:
		view.enter_room(_room.map, _renderer.local_pixels_per_meter, start)


func _spawn_enemies(map: RoomMap, start: Vector2i) -> void:
	var targets: Array[Node2D] = [_hero_proxy]
	for cell: Vector2i in _enemy_spawn_cells(map, start, ENEMIES_PER_ROOM):
		var enemy := BasicEnemy.new()
		enemy.definition = ENEMY_TRES
		enemy.damage_system = _damage_system
		enemy.status_config = _status_config
		_renderer.actors.add_child(enemy)
		enemy.enter_room(map, _renderer.local_pixels_per_meter, cell, targets,
				_actor_ids.allocate())
		var hurtbox := Hurtbox2D.new()
		hurtbox.combatant = enemy.combat
		var shape_node := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = maxf(enemy.definition.radius, 0.25) * _renderer.local_pixels_per_meter
		shape_node.shape = circle
		hurtbox.add_child(shape_node)
		enemy.add_child(hurtbox)
		_enemies.append(enemy)


## Deterministic spread of walkable cells at least MIN_SPAWN_DISTANCE away from the
## hero; falls back to any walkable cell when the room is too small.
func _enemy_spawn_cells(map: RoomMap, start: Vector2i, count: int) -> Array[Vector2i]:
	var far: Array[Vector2i] = []
	var near: Array[Vector2i] = []
	for i in map.cell_count():
		var c := map.cell(i)
		if not map.is_walkable(c):
			continue
		if Vector2(c - start).length() >= MIN_SPAWN_DISTANCE:
			far.append(c)
		else:
			near.append(c)
	var pool: Array[Vector2i] = far if far.size() >= count else far + near
	pool.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	if pool.size() <= count:
		return pool
	var chosen: Array[Vector2i] = []
	var last := -1
	for k in count:
		var index := int(round(float(k) * (pool.size() - 1) / float(count - 1)))
		if index == last:
			continue
		chosen.append(pool[index])
		last = index
	return chosen


func _clear_enemies() -> void:
	_enemies.clear()
	_dying.clear()
	for child: Node in _renderer.actors.get_children():
		if child is BasicEnemy:
			child.queue_free()


func _clear_strikes() -> void:
	for strike: Strike in _strikes:
		strike.node.end_attack()
		strike.node.queue_free()
	_strikes.clear()


func _process(delta: float) -> void:
	_performance.text = "%d FPS\n%.2f ms" % [Engine.get_frames_per_second(), delta * 1000.0]
	_shake_left = maxf(0.0, _shake_left - delta)
	for index: int in _party.states.size():
		if _hero_hp_last[index] > _party.states[index].hp and not _no_shake:
			_shake_left = SHAKE_DURATION
		_hero_hp_last[index] = _party.states[index].hp
	_update_hud()


func _physics_process(_delta: float) -> void:
	if _room == null:
		return
	for enemy: BasicEnemy in _enemies:
		enemy.tick()
	_tick_strikes()
	_damage_system.flush()
	_tick_dying_enemies()
	if _party.party_alive() and not _party.active_state().alive:
		# The active hero fell: hand control to the next alive one so the enemy
		# proxy retargets (request_swap_next skips the dead).
		_party.request_swap_next()
	var c := _active_view().cell()
	if not _room.map.in_bounds(c):
		# Left the room: only possible through a door.
		var dir := T.Dir.NORTH if c.y < 0 else T.Dir.SOUTH if c.y >= _room.size.y else T.Dir.WEST if c.x < 0 else T.Dir.EAST
		var next := _dungeon.neighbor(_room, dir)
		if next != null:
			_show_room(next, T.opposite(dir))
			return
	if _renderer.props_layer != null:
		_renderer.props_layer.update_fade(PackedVector2Array([_active_view().position]),
				_active_view().height * _active_view().pixels_per_meter)
	_overlay.hero_level = _active_view().level
	_update_camera()
	_update_hero_info()


func _on_hero_input_frame(frame: HeroInputFrame) -> void:
	_party.apply_input(frame)
	_party.tick()


func _active_view() -> CombatHeroView:
	return _views[_party.active_index()]


func _on_hero_activated(index: int) -> void:
	_views[index].active = true
	_hero_proxy.combatant_state = _party.states[index]


func _on_hero_deactivated(index: int) -> void:
	_views[index].active = false


## Manual attack: a short-lived melee arc in front of the hero, resolved by the
## hitbox/hurtbox overlap on the next physics ticks through the shared HitRegistry.
func _on_attack_fired(attack: AttackDefinition, origin: Vector2, direction: Vector2) -> void:
	_spawn_strike(attack, origin, direction, 0.9, 0.9, 8)


## Skill: an instant burst around the hero on the fire tick.
func _on_skill_fired(attack: AttackDefinition, origin: Vector2, _direction: Vector2) -> void:
	_spawn_strike(attack, origin, Vector2.ZERO, 2.6, 0.0, 4)


func _spawn_strike(attack: AttackDefinition, origin_m: Vector2, direction: Vector2,
		radius_m: float, forward_m: float, lifetime: int) -> void:
	var hitbox := Hitbox2D.new()
	hitbox.attack = attack
	hitbox.source = _party.active_state()
	hitbox.damage_system = _damage_system
	hitbox.registry = _registry
	_attack_serial += 1
	hitbox.attack_instance_id = _attack_serial
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius_m * _renderer.local_pixels_per_meter
	shape_node.shape = circle
	hitbox.add_child(shape_node)
	var dir := direction.normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.DOWN
	hitbox.position = (origin_m + dir * forward_m) * _renderer.local_pixels_per_meter
	_renderer.actors.add_child(hitbox)
	var strike := Strike.new()
	strike.node = hitbox
	strike.ticks = lifetime
	_strikes.append(strike)


func _tick_strikes() -> void:
	for index: int in range(_strikes.size() - 1, -1, -1):
		var strike := _strikes[index]
		strike.node.tick()
		strike.ticks -= 1
		if strike.ticks <= 0:
			strike.node.end_attack()
			strike.node.queue_free()
			_strikes.remove_at(index)


func _tick_dying_enemies() -> void:
	for enemy: BasicEnemy in _enemies:
		if enemy.combat != null and not enemy.combat.alive and _find_dying(enemy) == null:
			var dying := DyingEnemy.new()
			dying.node = enemy
			dying.ticks = 24
			_dying.append(dying)
			var body: Polygon2D = enemy.get("_body")
			if body != null:
				var tween := enemy.create_tween()
				tween.tween_property(body, "scale", Vector2.ZERO, 0.4)
	for index: int in range(_dying.size() - 1, -1, -1):
		var dying := _dying[index]
		dying.ticks -= 1
		if dying.ticks <= 0:
			_enemies.erase(dying.node)
			dying.node.queue_free()
			_dying.remove_at(index)


func _find_dying(enemy: BasicEnemy) -> DyingEnemy:
	for dying: DyingEnemy in _dying:
		if dying.node == enemy:
			return dying
	return null


func _update_camera() -> void:
	if _follow:
		_camera.zoom = Vector2.ONE * _fit_zoom * _zoom_factor * 3.0
		_camera.position = _clamp_camera_position(_active_view().global_position,
				WorldUnits.cell_to_pixels(_room.size), get_viewport_rect().size, _camera.zoom)
	else:
		_camera.zoom = Vector2.ONE * _fit_zoom * _zoom_factor
		_camera.position = _fit_position
	if _shake_left > 0.0 and not _no_shake:
		var strength := 10.0 * _shake_left / SHAKE_DURATION
		_camera.position += Vector2(randf_range(-strength, strength), randf_range(-strength, strength))


static func _clamp_camera_position(target: Vector2, room_size: Vector2,
		viewport_size: Vector2, zoom: Vector2) -> Vector2:
	var half_view := viewport_size / zoom * 0.5
	return Vector2(
		room_size.x * 0.5 if half_view.x * 2.0 >= room_size.x
				else clampf(target.x, half_view.x, room_size.x - half_view.x),
		room_size.y * 0.5 if half_view.y * 2.0 >= room_size.y
				else clampf(target.y, half_view.y, room_size.y - half_view.y)
	)


func _build_hud(ui: CanvasLayer) -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 108)
	ui.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	for index: int in PartyController.PARTY_SIZE:
		var name_label := Label.new()
		box.add_child(name_label)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(180, 12)
		bar.max_value = 100.0
		bar.show_percentage = false
		box.add_child(bar)
		var status_label := Label.new()
		box.add_child(status_label)
		_hud_names.append(name_label)
		_hud_bars.append(bar)
		_hud_statuses.append(status_label)
	_hud_party = Label.new()
	box.add_child(_hud_party)


func _update_hud() -> void:
	if _party == null or _party.states.is_empty():
		return
	const STATUS_NAMES := ["burn", "poison", "chill", "freeze", "stun", "bleed"]
	for index: int in _party.states.size():
		var state := _party.states[index]
		_hud_bars[index].value = state.health_ratio() * 100.0
		var marker := ">" if index == _party.active_index() else "-"
		var max_hp := int(ceil(state.modifiers.get_stats().max_hp))
		_hud_names[index].text = "%s P%d  %s  %d/%d" % [marker, index + 1,
				state.hero_definition.display_name, int(ceil(state.hp)), max_hp] \
				if state.alive else "%s P%d  DEAD" % [marker, index + 1]
		var tags := PackedStringArray()
		for status: int in range(1, STATUS_NAMES.size() + 1):
			if state.statuses.stacks[status] > 0:
				tags.append("%s x%d" % [STATUS_NAMES[status - 1], state.statuses.stacks[status]])
		_hud_statuses[index].text = ", ".join(tags)


	var active := _party.active_state()
	var tps := float(_party.ticks_per_second)
	_hud_party.text = "skill %.1fs | dash %.1fs | swap %.1fs | enemies %d%s" % [
		active.skill_cooldown_left / tps, active.dash_cooldown_left / tps,
		_party.swap_cooldown_left / tps, _enemies_alive(),
		" | PARTY WIPED — R" if not _party.party_alive() else ""]


func _enemies_alive() -> int:
	var alive := 0
	for enemy: BasicEnemy in _enemies:
		if enemy.combat != null and enemy.combat.alive:
			alive += 1
	return alive


func _update_info() -> void:
	var map := _room.map
	var doors := PackedStringArray()
	for dir in _room.neighbors:
		doors.append(T.dir_name(dir))
	_info.set_meta("room_text", "seed %d | %s | %d rooms (%s) | generated in %d ms\nroom %d: %s, %dx%d, depth %d, attempt %d | doors: %s | stairs %d, props %d" % [
		_seed, _dungeon.biome.display_name, _dungeon.rooms.size(), "shop" if _dungeon.shop_index >= 0 else "no shop", _gen_msec,
		_room.index, T.room_type_name(_room.type), _room.size.x, _room.size.y, _room.depth, _room.attempts,
		", ".join(doors), map.stairs.size(), map.props.size()])
	_update_hero_info()
	_minimap.queue_redraw()


func _update_hero_info() -> void:
	var view := _active_view()
	var m := view.meters()
	var state := _party.active_state()
	_info.text = "%s\nhero: (%.1f, %.1f) m, cell %s, level %d, hp %d/%d | enemies alive %d\n[WASD] move [LMB] attack [RMB] skill [Space] dash [1/2/3] swap [F] follow [R] seed [B] biome [arrows] door [Tab] room [O] overlay" % [
		_info.get_meta("room_text", ""), m.x, m.y, view.cell(), view.level,
		int(ceil(state.hp)), int(ceil(state.modifiers.get_stats().max_hp)), _enemies_alive()]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_factor *= 1.1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_factor /= 1.1
		_update_camera()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_R:
			_seed = randi()
			_generate()
		KEY_B:
			_biome_index = (_biome_index + 1) % _biomes.size()
			_generate()
		KEY_TAB:
			_show_room(_dungeon.rooms[(_room.index + 1) % _dungeon.rooms.size()])
		KEY_O:
			_overlay.visible = not _overlay.visible
		KEY_F:
			_follow = not _follow
			_update_camera()
		KEY_UP:
			_go(T.Dir.NORTH)
		KEY_RIGHT:
			_go(T.Dir.EAST)
		KEY_DOWN:
			_go(T.Dir.SOUTH)
		KEY_LEFT:
			_go(T.Dir.WEST)


func _go(dir: int) -> void:
	var next := _dungeon.neighbor(_room, dir)
	if next != null:
		_show_room(next)
