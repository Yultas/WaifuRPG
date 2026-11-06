class_name RoomMap
extends RefCounted
## Grid description of one room. Rendering-agnostic: the tile renderer and the collision
## builder read only this data, never the generator internals.
##
## Movement rules: a step between two walkable cells is allowed when they are on the same
## level, or when both are stair cells of one column (stairs climb north). Bridges are
## walkable only along their axis.

const T := preload("res://src/dungeon/dungeon_types.gd")


## A door opening on the room boundary.
class Door:
	var dir: int
	## Walkable cells on the outer edge of the room, where the party enters.
	var edge_cells: Array[Vector2i] = []
	## Walkable cells cut through the border, edge cells included.
	var corridor: Array[Vector2i] = []
	## First cell inside the border on the door's center line.
	var inner := Vector2i.ZERO


class PlacedProp:
	var prop: PropDef
	## Bottom-left cell of the footprint.
	var cell := Vector2i.ZERO

	func _init(p: PropDef, c: Vector2i) -> void:
		prop = p
		cell = c


var size: Vector2i
## Elevation level, 0..2.
var level := PackedByteArray()
## DungeonTypes.Terrain.
var terrain := PackedByteArray()
## DungeonTypes.Structure.
var structure := PackedByteArray()
## 1 = room boundary, never walkable.
var wall := PackedByteArray()
## 1 = must stay flat dry ground (door approaches, special room centers).
var keep_flat := PackedByteArray()
## 1 = lush grass surface, visual only.
var lush := PackedByteArray()
## 1 = main path between the center and the doors.
var path := PackedByteArray()
## 1 = road surface: the main paths widened to 2 cells, kept off shores and cliff edges.
var road := PackedByteArray()
## 1 = covered by a prop footprint.
var occupied := PackedByteArray()
## 1 = movement blocked by a prop.
var blocked := PackedByteArray()

var doors: Array[Door] = []
## Focus point of the room (arena center, shopkeeper, boss spot).
var center := Vector2i.ZERO
## Top-left cell of each 2x2 stair block: the top row is the cliff edge of the upper
## level, the bottom row lies on the lower level.
var stairs: Array[Vector2i] = []
var props: Array[PlacedProp] = []


func _init(map_size: Vector2i) -> void:
	size = map_size
	var n := size.x * size.y
	level.resize(n)
	terrain.resize(n)
	structure.resize(n)
	wall.resize(n)
	keep_flat.resize(n)
	lush.resize(n)
	path.resize(n)
	road.resize(n)
	occupied.resize(n)
	blocked.resize(n)


func cell_count() -> int:
	return size.x * size.y


func idx(c: Vector2i) -> int:
	return c.y * size.x + c.x


func cell(i: int) -> Vector2i:
	@warning_ignore("integer_division")
	return Vector2i(i % size.x, i / size.x)


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < size.x and c.y < size.y


func level_at(c: Vector2i) -> int:
	return level[idx(c)]


func is_water(c: Vector2i) -> bool:
	return terrain[idx(c)] == T.Terrain.WATER


func is_land(c: Vector2i) -> bool:
	return terrain[idx(c)] == T.Terrain.LAND


func is_bridge(c: Vector2i) -> bool:
	var s := structure[idx(c)]
	return s == T.Structure.BRIDGE_H or s == T.Structure.BRIDGE_V


## Upper-level cell whose south neighbour is lower: the cliff face is drawn on it.
func is_cliff_face(c: Vector2i) -> bool:
	var below := c + Vector2i.DOWN
	return in_bounds(below) and level[idx(below)] < level[idx(c)]


## Walkable terrain, props ignored: dry land or a bridge, not part of the border.
func is_ground(c: Vector2i) -> bool:
	if not in_bounds(c):
		return false
	var i := idx(c)
	if wall[i] != 0:
		return false
	if terrain[i] == T.Terrain.LAND:
		return true
	var s := structure[i]
	return s == T.Structure.BRIDGE_H or s == T.Structure.BRIDGE_V


func is_walkable(c: Vector2i) -> bool:
	return is_ground(c) and blocked[idx(c)] == 0


func can_step(from: Vector2i, dir: int) -> bool:
	var to := from + T.DIR_VECTORS[dir]
	return is_walkable(from) and is_walkable(to) and can_cross(from, dir)


## Terrain rule for the edge between two ground cells (props ignored): same level, or a
## stair column; bridges only along their axis. Never true across a cliff.
func can_cross(from: Vector2i, dir: int) -> bool:
	var to := from + T.DIR_VECTORS[dir]
	if not is_ground(from) or not is_ground(to):
		return false
	var horizontal := T.is_horizontal(dir)
	var a := idx(from)
	var b := idx(to)
	for s in [structure[a], structure[b]]:
		if s == T.Structure.BRIDGE_H and not horizontal:
			return false
		if s == T.Structure.BRIDGE_V and horizontal:
			return false
	if level[a] == level[b]:
		return true
	return not horizontal and structure[a] == T.Structure.STAIRS and structure[b] == T.Structure.STAIRS


## Cells that must be mutually reachable: the center and every door.
func key_cells() -> Array[Vector2i]:
	var keys: Array[Vector2i] = [center]
	for door in doors:
		keys.append(door.inner)
	return keys


func door(dir: int) -> Door:
	for d in doors:
		if d.dir == dir:
			return d
	return null


## Connected walkable regions under the movement rules; -1 for non-walkable cells.
func compute_regions() -> PackedInt32Array:
	var labels := PackedInt32Array()
	labels.resize(cell_count())
	labels.fill(-1)
	var next_label := 0
	var queue := PackedInt32Array()
	for start in cell_count():
		if labels[start] != -1 or not is_walkable(cell(start)):
			continue
		labels[start] = next_label
		queue.clear()
		queue.append(start)
		var head := 0
		while head < queue.size():
			var c := cell(queue[head])
			head += 1
			for dir in 4:
				var n := c + T.DIR_VECTORS[dir]
				if not in_bounds(n):
					continue
				var ni := idx(n)
				if labels[ni] == -1 and can_step(c, dir):
					labels[ni] = next_label
					queue.append(ni)
		next_label += 1
	return labels


func reachable_from(start: Vector2i) -> PackedByteArray:
	var reached := PackedByteArray()
	reached.resize(cell_count())
	if not is_walkable(start):
		return reached
	var queue := PackedInt32Array([idx(start)])
	reached[idx(start)] = 1
	var head := 0
	while head < queue.size():
		var c := cell(queue[head])
		head += 1
		for dir in 4:
			var n := c + T.DIR_VECTORS[dir]
			if in_bounds(n) and reached[idx(n)] == 0 and can_step(c, dir):
				reached[idx(n)] = 1
				queue.append(idx(n))
	return reached


## Shortest walkable path (BFS), both ends included. Empty when unreachable.
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not is_walkable(from) or not is_walkable(to):
		return result
	var parent := PackedInt32Array()
	parent.resize(cell_count())
	parent.fill(-1)
	var start := idx(from)
	var goal := idx(to)
	parent[start] = start
	var queue := PackedInt32Array([start])
	var head := 0
	while head < queue.size() and parent[goal] == -1:
		var c := cell(queue[head])
		head += 1
		for dir in 4:
			var n := c + T.DIR_VECTORS[dir]
			if in_bounds(n) and parent[idx(n)] == -1 and can_step(c, dir):
				parent[idx(n)] = idx(c)
				queue.append(idx(n))
	if parent[goal] == -1:
		return result
	var i := goal
	while i != start:
		result.append(cell(i))
		i = parent[i]
	result.append(from)
	result.reverse()
	return result


## Closest dry, non-wall, structure-free cell to target. Ground level is preferred:
## a cell on high ground counts as a few cells farther away.
func nearest_open_land(target: Vector2i) -> Vector2i:
	var best := target
	var best_dist := INF
	for i in cell_count():
		if wall[i] != 0 or terrain[i] != T.Terrain.LAND or structure[i] != T.Structure.NONE:
			continue
		var d := Vector2(cell(i) - target).length() + level[i] * 6.0
		if d < best_dist:
			best_dist = d
			best = cell(i)
	return best


func checksum() -> int:
	var parts := [size, level, terrain, structure, wall, lush, path, road, occupied, blocked, center, stairs]
	for p in props:
		parts.append(p.prop.id)
		parts.append(p.cell)
	return hash(parts)
