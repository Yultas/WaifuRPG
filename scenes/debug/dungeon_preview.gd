extends Node2D
## Debug viewer for the dungeon generator.
## WASD walk (leave through a door to enter the next room), F camera follows the hero,
## R new seed, B next biome, arrows jump through doors, Tab next room, O debug overlay,
## mouse wheel zoom.
## Command line (after `--`): --seed=N --biome=<id из data/biomes or path to a biome .tres>
## --room=N|boss|shop --overlay
## --follow --hero=x,y (start cell) --screenshot=path.png (renders once, saves and quits).

const T := preload("res://src/dungeon/dungeon_types.gd")
const CONFIG := preload("res://data/dungeon/default_dungeon.tres")
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

var _renderer: RoomTileRenderer
var _overlay: RoomDebugOverlay
var _hero: TestHero
var _camera: Camera2D
var _follow := false
var _zoom_factor := 1.0
var _fit_zoom := 1.0
var _fit_position := Vector2.ZERO
var _info: Label
var _minimap: Minimap


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
	_renderer = RoomTileRenderer.new()
	add_child(_renderer)
	_hero = TestHero.new()
	_renderer.actors.add_child(_hero)
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
		_hero.enter_room(_room.map, _renderer.local_pixels_per_meter, hero_cell)
	if not screenshot.is_empty():
		for _frame in 3:
			await get_tree().physics_frame
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
	var start := map.center
	var door := map.door(entry_dir)
	if door != null:
		start = door.edge_cells[door.edge_cells.size() / 2] - T.DIR_VECTORS[entry_dir]
	_hero.enter_room(map, _renderer.local_pixels_per_meter, start)
	_overlay.show_map(map, _dungeon.biome.tile_theme.cliff_face_depth)
	# Fit the room into the area left of the minimap and below the info text.
	var world := WorldUnits.cell_to_pixels(room.size)
	var view := get_viewport_rect().size
	var usable := Rect2(16, 84, view.x - 312, view.y - 100)
	_fit_zoom = minf(usable.size.x / world.x, usable.size.y / world.y)
	_fit_position = world * 0.5 - (usable.get_center() - view * 0.5) / _fit_zoom
	_update_camera()
	_update_info()


func _physics_process(_delta: float) -> void:
	if _room == null:
		return
	var c := _hero.cell()
	if not _room.map.in_bounds(c):
		# Left the room: only possible through a door.
		var dir := T.Dir.NORTH if c.y < 0 else T.Dir.SOUTH if c.y >= _room.size.y else T.Dir.WEST if c.x < 0 else T.Dir.EAST
		var next := _dungeon.neighbor(_room, dir)
		if next != null:
			_show_room(next, T.opposite(dir))
			return
	if _renderer.props_layer != null:
		_renderer.props_layer.update_fade(PackedVector2Array([_hero.position]), _hero.height * _hero.pixels_per_meter)
	_overlay.hero_level = _hero.level
	_update_camera()
	_update_hero_info()


func _update_camera() -> void:
	if _follow:
		_camera.zoom = Vector2.ONE * _fit_zoom * _zoom_factor * 3.0
		_camera.position = _hero.global_position
	else:
		_camera.zoom = Vector2.ONE * _fit_zoom * _zoom_factor
		_camera.position = _fit_position


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
	var m := _hero.meters()
	_info.text = "%s\nhero: (%.1f, %.1f) m, cell %s, level %d\n[WASD] walk  [F] follow  [R] new seed  [B] biome  [arrows] jump through door  [Tab] next room  [O] overlay" % [
		_info.get_meta("room_text", ""), m.x, m.y, _hero.cell(), _hero.level]


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
