class_name RoomCollision
extends RefCounted
## Collision geometry of a room, built from RoomMap (never from tiles), one set per
## elevation level. A character collides only with the walls of the level it stands on and
## changes level only on stairs, so a cliff is always a wall: no jumping down.
##
## The room is sampled at half-cell resolution. On level L a sub-cell is open when its cell
## is ground on L (stair cells belong to both levels they join). Walls are the edges between
## open and closed sub-cells, the room boundary except door openings, and edges the terrain
## forbids between open cells (bridge sides). Output is in meters (see WorldUnits).

const T := preload("res://src/dungeon/dungeon_types.gd")
## Sub-cells per cell side.
const SUB := 2


## Wall segments for characters standing on `level`, as point pairs in meters.
## face_depth: depth (in cells) of the cliff face drawn on the south edge of high ground.
## Characters on the upper level stop at the top of the face (0.5 for the current tiles).
static func wall_segments(map: RoomMap, level: int, face_depth := 0.5) -> PackedVector2Array:
	var face_rows := clampi(roundi(face_depth * SUB), 0, SUB)
	var w := map.size.x * SUB
	var h := map.size.y * SUB
	var open := PackedByteArray()
	open.resize(w * h)
	for i in map.cell_count():
		var c := map.cell(i)
		if not _open_on(map, c, level):
			continue
		var closed_rows := face_rows if _is_face_on(map, c, level) else 0
		for sy in SUB - closed_rows:
			for sx in SUB:
				open[(c.y * SUB + sy) * w + c.x * SUB + sx] = 1

	# Edge grids: horizontal edges lie on sub-row lines (h + 1 lines of w edges), vertical
	# edges on sub-column lines (w + 1 lines of h edges).
	var h_edges := PackedByteArray()
	h_edges.resize(w * (h + 1))
	var v_edges := PackedByteArray()
	v_edges.resize((w + 1) * h)
	var door_edges := _door_edges(map)
	for sy in h:
		for sx in w:
			if open[sy * w + sx] == 0:
				continue
			var cell := Vector2i(sx / SUB, sy / SUB)
			for dir in 4:
				var v := T.DIR_VECTORS[dir]
				var nx := sx + v.x
				var ny := sy + v.y
				var wall := false
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					wall = not door_edges.has(Vector3i(cell.x, cell.y, dir))
				elif open[ny * w + nx] == 0:
					wall = true
				else:
					var other := Vector2i(nx / SUB, ny / SUB)
					# Both open but in different cells the terrain forbids crossing. Mark it
					# from one side only.
					wall = other != cell and (dir == T.Dir.EAST or dir == T.Dir.SOUTH) and not map.can_cross(cell, dir)
				if not wall:
					continue
				match dir:
					T.Dir.NORTH:
						h_edges[sy * w + sx] = 1
					T.Dir.SOUTH:
						h_edges[(sy + 1) * w + sx] = 1
					T.Dir.WEST:
						v_edges[sx * h + sy] = 1
					_:
						v_edges[(sx + 1) * h + sy] = 1

	var segments := PackedVector2Array()
	var unit := WorldUnits.CELL_SIZE / SUB
	for line in h + 1:
		var start := -1
		for sx in w + 1:
			var on := sx < w and h_edges[line * w + sx] != 0
			if on and start < 0:
				start = sx
			elif not on and start >= 0:
				segments.append(Vector2(start, line) * unit)
				segments.append(Vector2(sx, line) * unit)
				start = -1
	for line in w + 1:
		var start := -1
		for sy in h + 1:
			var on := sy < h and v_edges[line * h + sy] != 0
			if on and start < 0:
				start = sy
			elif not on and start >= 0:
				segments.append(Vector2(line, start) * unit)
				segments.append(Vector2(line, sy) * unit)
				start = -1
	return segments


## Collision boxes (meters) of blocking props standing on `level`: the trunk or base,
## at the bottom of the footprint.
static func prop_boxes(map: RoomMap, level: int) -> Array[Rect2]:
	var boxes: Array[Rect2] = []
	for placed in map.props:
		var prop := placed.prop
		if not prop.blocking or prop.collision_size == Vector2.ZERO or map.level_at(placed.cell) != level:
			continue
		var base := Vector2(placed.cell.x + prop.size.x * 0.5, placed.cell.y + 1.0) * WorldUnits.CELL_SIZE
		var center := base - Vector2(0.0, prop.collision_size.y * 0.5 + prop.collision_lift)
		boxes.append(Rect2(center - prop.collision_size * 0.5, prop.collision_size))
	return boxes


static func max_level(map: RoomMap) -> int:
	var top := 0
	for l in map.level:
		top = maxi(top, l)
	return top


## Physics layer bit used by walls of the given level.
static func layer_bit(level: int) -> int:
	return 1 << level


## Builds StaticBody2D nodes (one per level, on that level's physics layer).
## pixels_per_meter is in the parent's local space.
static func build_2d(map: RoomMap, pixels_per_meter: float, face_depth := 0.5) -> Node2D:
	var root := Node2D.new()
	root.name = "Collision"
	for level in max_level(map) + 1:
		var body := StaticBody2D.new()
		body.name = "Level%d" % level
		body.collision_layer = layer_bit(level)
		body.collision_mask = 0
		root.add_child(body)
		var segments := wall_segments(map, level, face_depth)
		for k in range(0, segments.size(), 2):
			var shape := SegmentShape2D.new()
			shape.a = segments[k] * pixels_per_meter
			shape.b = segments[k + 1] * pixels_per_meter
			var node := CollisionShape2D.new()
			node.shape = shape
			body.add_child(node)
		for box in prop_boxes(map, level):
			var shape := RectangleShape2D.new()
			shape.size = box.size * pixels_per_meter
			var node := CollisionShape2D.new()
			node.shape = shape
			node.position = box.get_center() * pixels_per_meter
			body.add_child(node)
	return root


## Ground on `level`: the cell's own level, or either level a stair cell joins.
static func _open_on(map: RoomMap, c: Vector2i, level: int) -> bool:
	if not map.is_ground(c):
		return false
	var l := map.level_at(c)
	if map.structure[map.idx(c)] != T.Structure.STAIRS:
		return l == level
	var below := c + Vector2i.DOWN
	var is_top := map.in_bounds(below) and map.structure[map.idx(below)] == T.Structure.STAIRS and map.level_at(below) < l
	return level == l or level == (l - 1 if is_top else l + 1)


## High-ground cell whose cliff face (drawn in its lower part) is not walkable on `level`.
static func _is_face_on(map: RoomMap, c: Vector2i, level: int) -> bool:
	return map.level_at(c) == level and map.structure[map.idx(c)] != T.Structure.STAIRS and map.is_cliff_face(c)


## Room-boundary edges that stay open: the outer side of door edge cells.
## Keys are Vector3i(cell.x, cell.y, dir).
static func _door_edges(map: RoomMap) -> Dictionary[Vector3i, bool]:
	var edges: Dictionary[Vector3i, bool] = {}
	for door in map.doors:
		for c in door.edge_cells:
			edges[Vector3i(c.x, c.y, door.dir)] = true
	return edges
