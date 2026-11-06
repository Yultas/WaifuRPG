class_name LayoutGenerator
extends RefCounted
## Places rooms on a grid (one grid cell per room) and links them into the dungeon graph:
## a random tree of regular rooms, the boss room in the dead end farthest from the start
## and, with some chance, a shop room in another dead end.

const T := preload("res://src/dungeon/dungeon_types.gd")
const MAX_ATTEMPTS := 64


## Returns a dungeon with rooms and links but without room maps, or null on failure.
static func generate(config: DungeonConfig, rng: RandomNumberGenerator) -> DungeonData:
	var max_rooms := maxi(config.max_rooms, 3)
	var min_rooms := clampi(config.min_rooms, 3, max_rooms)
	var total := rng.randi_range(min_rooms, max_rooms)
	var with_shop := total >= 4 and rng.randf() < config.shop_chance
	var regular := total - 1 - int(with_shop)
	for _attempt in MAX_ATTEMPTS:
		var dungeon := _try_layout(config, rng, regular, with_shop)
		if dungeon != null:
			return dungeon
	push_error("LayoutGenerator: could not place %d rooms" % total)
	return null


static func _try_layout(config: DungeonConfig, rng: RandomNumberGenerator, regular: int, with_shop: bool) -> DungeonData:
	var positions: Array[Vector2i] = [Vector2i.ZERO]
	var occupied: Dictionary[Vector2i, int] = {Vector2i.ZERO: 0}
	var links: Array[Vector2i] = []

	# Random tree. A new room may touch only its parent, which keeps branches apart
	# and makes dead ends common.
	var guard := 0
	while positions.size() < regular and guard < 2000:
		guard += 1
		var from := rng.randi_range(0, positions.size() - 1)
		if rng.randf() < 0.5:
			from = rng.randi_range(positions.size() / 2, positions.size() - 1)
		var p := positions[from] + T.DIR_VECTORS[rng.randi_range(0, 3)]
		if occupied.has(p) or _count_neighbors(occupied, p) != 1:
			continue
		occupied[p] = positions.size()
		links.append(Vector2i(from, positions.size()))
		positions.append(p)
	if positions.size() < regular:
		return null

	# Optional loops between adjacent regular rooms.
	for i in positions.size():
		for dir: int in [T.Dir.EAST, T.Dir.SOUTH]:
			var q := positions[i] + T.DIR_VECTORS[dir]
			if occupied.has(q) and not _linked(links, i, occupied[q]) and rng.randf() < config.extra_connection_chance:
				links.append(Vector2i(i, occupied[q]))

	# Boss: a new dead end hanging off the deepest possible room (never off the start).
	var depth := _depths(positions.size(), links)
	var boss_spot := _pick_dead_end(positions, occupied, depth, rng, [0], true)
	if boss_spot.is_empty():
		return null
	var boss_index := positions.size()
	occupied[boss_spot.pos] = boss_index
	links.append(Vector2i(boss_spot.parent, boss_index))
	positions.append(boss_spot.pos)

	# Shop: another dead end, not next to the boss (the neighbour count rule ensures it).
	var shop_index := -1
	if with_shop:
		var shop_spot := _pick_dead_end(positions, occupied, depth, rng, [boss_index], false)
		if shop_spot.is_empty():
			return null
		shop_index = positions.size()
		occupied[shop_spot.pos] = shop_index
		links.append(Vector2i(shop_spot.parent, shop_index))
		positions.append(shop_spot.pos)

	return _build(config, rng, positions, links, boss_index, shop_index)


## Free grid cell touching exactly one room. With `deepest`, only cells attached to the
## deepest rooms are considered.
static func _pick_dead_end(positions: Array[Vector2i], occupied: Dictionary[Vector2i, int], depth: PackedInt32Array,
		rng: RandomNumberGenerator, excluded_parents: Array, deepest: bool) -> Dictionary:
	var candidates: Array[Dictionary] = []
	var best := -1
	for i in depth.size():
		if excluded_parents.has(i) and positions.size() > 1:
			continue
		for dir in 4:
			var p := positions[i] + T.DIR_VECTORS[dir]
			if occupied.has(p) or _count_neighbors(occupied, p) != 1:
				continue
			if deepest and depth[i] < best:
				continue
			if deepest and depth[i] > best:
				best = depth[i]
				candidates.clear()
			candidates.append({"pos": p, "parent": i})
	if candidates.is_empty():
		return {}
	return candidates[rng.randi_range(0, candidates.size() - 1)]


static func _build(config: DungeonConfig, rng: RandomNumberGenerator, positions: Array[Vector2i],
		links: Array[Vector2i], boss_index: int, shop_index: int) -> DungeonData:
	var dungeon := DungeonData.new()
	dungeon.boss_index = boss_index
	dungeon.shop_index = shop_index
	var depth := _depths(positions.size(), links)
	for i in positions.size():
		var room := RoomData.new()
		room.index = i
		room.grid_pos = positions[i]
		room.depth = depth[i]
		if i == 0:
			room.type = T.RoomType.START
			room.size = config.start_room_size
		elif i == boss_index:
			room.type = T.RoomType.BOSS
			room.size = config.boss_room_size
		elif i == shop_index:
			room.type = T.RoomType.SHOP
			room.size = config.shop_room_size
		else:
			room.type = T.RoomType.COMBAT
			room.size = Vector2i(
				rng.randi_range(config.combat_room_min.x, config.combat_room_max.x),
				rng.randi_range(config.combat_room_min.y, config.combat_room_max.y))
		dungeon.rooms.append(room)
	for link in links:
		var a := dungeon.rooms[link.x]
		var b := dungeon.rooms[link.y]
		var dir := T.DIR_VECTORS.find(b.grid_pos - a.grid_pos)
		a.neighbors[dir] = b.index
		b.neighbors[T.opposite(dir)] = a.index
	return dungeon


static func _count_neighbors(occupied: Dictionary[Vector2i, int], p: Vector2i) -> int:
	var count := 0
	for v in T.DIR_VECTORS:
		if occupied.has(p + v):
			count += 1
	return count


static func _linked(links: Array[Vector2i], a: int, b: int) -> bool:
	return links.has(Vector2i(a, b)) or links.has(Vector2i(b, a))


## BFS distance (in doors) from room 0.
static func _depths(count: int, links: Array[Vector2i]) -> PackedInt32Array:
	var depth := PackedInt32Array()
	depth.resize(count)
	depth.fill(-1)
	depth[0] = 0
	var queue := [0]
	while not queue.is_empty():
		var r: int = queue.pop_front()
		for link in links:
			var other := -1
			if link.x == r:
				other = link.y
			elif link.y == r:
				other = link.x
			if other >= 0 and other < count and depth[other] == -1:
				depth[other] = depth[r] + 1
				queue.append(other)
	return depth
