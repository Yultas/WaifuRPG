class_name RoomDebugOverlay
extends Node2D
## Debug drawing on top of a rendered room: walls, blocked cells, unreachable ground,
## main paths, stairs, doors, the center, and the collision of every level (the hero's
## level bright, the others faint).

const T := preload("res://src/dungeon/dungeon_types.gd")
const CELL := WorldUnits.CELL_PIXELS
const LEVEL_COLORS: Array[Color] = [Color(1.0, 0.2, 0.2), Color(0.2, 0.6, 1.0), Color(1.0, 0.3, 1.0)]

var map: RoomMap
var hero_level := 0:
	set(value):
		if value != hero_level:
			hero_level = value
			queue_redraw()

var _walls: Array[PackedVector2Array] = []
var _boxes: Array[Array] = []


func show_map(room_map: RoomMap, face_depth: float) -> void:
	map = room_map
	_walls.clear()
	_boxes.clear()
	for level in RoomCollision.max_level(map) + 1:
		_walls.append(RoomCollision.wall_segments(map, level, face_depth))
		_boxes.append(RoomCollision.prop_boxes(map, level))
	queue_redraw()


func _draw() -> void:
	if map == null:
		return
	var reached := map.reachable_from(map.center)
	for i in map.cell_count():
		var rect := Rect2(WorldUnits.cell_to_pixels(map.cell(i)), Vector2(CELL, CELL))
		if map.wall[i] != 0:
			draw_rect(rect, Color(0.9, 0.1, 0.1, 0.18))
		elif map.is_walkable(map.cell(i)) and reached[i] == 0:
			draw_rect(rect, Color(0.6, 0.0, 0.9, 0.3))
		if map.path[i] != 0:
			draw_rect(rect.grow(-6), Color(1.0, 0.9, 0.1, 0.8))
	for top in map.stairs:
		draw_rect(Rect2(WorldUnits.cell_to_pixels(top), Vector2(CELL * 2, CELL * 2)), Color.CYAN, false, 1.0)
	for door in map.doors:
		for c in door.edge_cells:
			draw_rect(Rect2(WorldUnits.cell_to_pixels(c), Vector2(CELL, CELL)), Color(0.2, 1.0, 0.3, 0.4))
	draw_circle(WorldUnits.cell_to_pixels(map.center) + Vector2.ONE * CELL * 0.5, CELL * 0.4, Color.RED)
	for level in _walls.size():
		var color := LEVEL_COLORS[level % LEVEL_COLORS.size()]
		color.a = 1.0 if level == hero_level else 0.25
		var width := 2.0 if level == hero_level else 1.0
		var segments := _walls[level]
		for k in range(0, segments.size(), 2):
			draw_line(segments[k] * WorldUnits.PIXELS_PER_METER, segments[k + 1] * WorldUnits.PIXELS_PER_METER, color, width)
		for box: Rect2 in _boxes[level]:
			draw_rect(Rect2(box.position * WorldUnits.PIXELS_PER_METER, box.size * WorldUnits.PIXELS_PER_METER), color, false, width)
