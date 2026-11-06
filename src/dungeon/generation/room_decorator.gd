class_name RoomDecorator
extends RefCounted
## Dresses a connected room: main paths, lush grass, border trees and scattered props.
## Props never land on reserved cells (paths and their shoulders, door approaches,
## clearings, stair and bridge ends), so blocking props cannot cut the room apart.

const T := preload("res://src/dungeon/dungeon_types.gd")
## Path cost of a cell where no road fits (1 where it does): paths bend to stay drawable
## as continuous roads instead of hugging cliffs and shores.
const OFF_ROAD_COST := 4
## Shorter road pieces are dropped: they would look like stray puddles.
const MIN_ROAD_CELLS := 6


static func decorate(map: RoomMap, room: RoomData, biome: BiomeData, rng: RandomNumberGenerator) -> void:
	_mark_paths(map)
	_mark_roads(map)
	var reserved := _reserve(map, room)
	_paint_lush(map, biome, rng)
	if biome.border_style == T.BorderStyle.TREES:
		_fill_border(map, biome, rng)
	_scatter_props(map, biome, rng, reserved)
	_open_pockets(map)


static func clearing_radius(room: RoomData) -> float:
	var short_side := mini(room.size.x, room.size.y)
	match room.type:
		T.RoomType.BOSS:
			return short_side / 3.0
		T.RoomType.SHOP:
			return 4.0
		T.RoomType.START:
			return 3.0
		_:
			return short_side / 6.0


static func _mark_paths(map: RoomMap) -> void:
	var step_cost := PackedInt32Array()
	step_cost.resize(map.cell_count())
	for i in map.cell_count():
		step_cost[i] = 1 if _road_fits(map, map.cell(i)) else OFF_ROAD_COST
	for door in map.doors:
		var target := door.edge_cells[door.edge_cells.size() / 2]
		for c in _road_friendly_path(map, map.center, target, step_cost):
			map.path[map.idx(c)] = 1


## Cheapest walkable path where cells that can hold a road cost less (Dial's algorithm:
## Dijkstra with a bucket per distance, as costs are small integers).
static func _road_friendly_path(map: RoomMap, from: Vector2i, to: Vector2i, step_cost: PackedInt32Array) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var dist := PackedInt32Array()
	dist.resize(map.cell_count())
	dist.fill(-1)
	var parent := PackedInt32Array()
	parent.resize(map.cell_count())
	var start := map.idx(from)
	var goal := map.idx(to)
	dist[start] = 0
	parent[start] = start
	var buckets: Array[PackedInt32Array] = [PackedInt32Array([start])]
	var d := 0
	while d < buckets.size() and dist[goal] != d:
		var k := 0
		while k < buckets[d].size():
			var i := buckets[d][k]
			k += 1
			if dist[i] != d:
				continue
			var c := map.cell(i)
			for dir in 4:
				var n := c + T.DIR_VECTORS[dir]
				if not map.in_bounds(n) or not map.can_step(c, dir):
					continue
				var ni := map.idx(n)
				var nd := d + step_cost[ni]
				if dist[ni] != -1 and dist[ni] <= nd:
					continue
				dist[ni] = nd
				parent[ni] = i
				while buckets.size() <= nd:
					buckets.append(PackedInt32Array())
				buckets[nd].append(ni)
		d += 1
	if dist[goal] == -1:
		return result
	var cur := goal
	while cur != start:
		result.append(map.cell(cur))
		cur = parent[cur]
	result.append(from)
	result.reverse()
	return result


## Roads follow the main paths with a 2x2 brush (2 cells wide). A road cell must sit in
## flat dry ground: all 8 neighbours on its level and dry (outside the room counts as
## fine, so roads run out through doors). That keeps road tiles off shores, cliff faces
## and the cells right below cliffs, where they could not be drawn cleanly. The brush
## stays inside the path's shoulders, which are reserved, so props never cover a road.
static func _mark_roads(map: RoomMap) -> void:
	for i in map.cell_count():
		if map.path[i] == 0:
			continue
		var c := map.cell(i)
		for o: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			var r := c + o
			if map.in_bounds(r) and _road_fits(map, r):
				map.road[map.idx(r)] = 1
	for piece in GridUtils.components(map.road, map.size):
		if piece.size() < MIN_ROAD_CELLS:
			for i in piece:
				map.road[i] = 0


static func _road_fits(map: RoomMap, c: Vector2i) -> bool:
	var i := map.idx(c)
	if not map.is_ground(c) or map.terrain[i] != T.Terrain.LAND or map.structure[i] != T.Structure.NONE:
		return false
	for o in T.AROUND_8:
		var n := c + o
		if not map.in_bounds(n):
			continue
		var ni := map.idx(n)
		if map.terrain[ni] != T.Terrain.LAND or map.level[ni] != map.level[i]:
			return false
	return true


static func _reserve(map: RoomMap, room: RoomData) -> PackedByteArray:
	var reserved := PackedByteArray()
	reserved.resize(map.cell_count())
	var radius := clearing_radius(room)
	for i in map.cell_count():
		var c := map.cell(i)
		if map.keep_flat[i] != 0 or Vector2(c - map.center).length() <= radius:
			reserved[i] = 1
		if map.path[i] == 0 and map.structure[i] == T.Structure.NONE:
			continue
		# Shoulders of paths and the ends of bridges and stairs.
		for o in T.AROUND_8:
			var n := c + o
			if map.in_bounds(n):
				reserved[map.idx(n)] = 1
		reserved[i] = 1
	for door in map.doors:
		for c in door.corridor:
			reserved[map.idx(c)] = 1
	return reserved


static func _paint_lush(map: RoomMap, biome: BiomeData, rng: RandomNumberGenerator) -> void:
	var noise := GridUtils.make_noise(rng.randi(), biome.vegetation_frequency * 1.5)
	var cells := PackedInt32Array()
	var values := PackedFloat32Array()
	for i in map.cell_count():
		if map.terrain[i] == T.Terrain.LAND and map.structure[i] == T.Structure.NONE:
			var c := map.cell(i)
			cells.append(i)
			values.append(noise.get_noise_2d(c.x, c.y))
	var threshold := GridUtils.quantile(values, 1.0 - biome.lush_amount)
	for k in cells.size():
		if values[k] > threshold:
			map.lush[cells[k]] = 1


## Packs the border with trees, biggest props first, so it reads as a forest wall.
static func _fill_border(map: RoomMap, biome: BiomeData, rng: RandomNumberGenerator) -> void:
	if biome.border_props.is_empty():
		return
	var by_size := biome.border_props.duplicate()
	by_size.sort_custom(func(a: PropDef, b: PropDef) -> bool: return a.size.x * a.size.y > b.size.x * b.size.y)
	for pass_index in by_size.size():
		var order := GridUtils.shuffled_indices(map.cell_count(), rng)
		for i in order:
			if map.wall[i] == 0 or map.occupied[i] != 0 or map.terrain[i] != T.Terrain.LAND:
				continue
			# On the first passes mix the big props, later ones fill the gaps.
			var prop: PropDef = by_size[pass_index]
			if pass_index == 0 and by_size.size() > 1 and rng.randf() < 0.35:
				prop = by_size[1]
			if _border_fits(map, prop, map.cell(i)):
				_place(map, prop, map.cell(i))


static func _border_fits(map: RoomMap, prop: PropDef, anchor: Vector2i) -> bool:
	for dy in prop.size.y:
		for dx in prop.size.x:
			var c := anchor + Vector2i(dx, -dy)
			if not map.in_bounds(c):
				return false
			var i := map.idx(c)
			if map.wall[i] == 0 or map.occupied[i] != 0 or map.terrain[i] != T.Terrain.LAND or map.structure[i] != T.Structure.NONE:
				return false
	return true


static func _scatter_props(map: RoomMap, biome: BiomeData, rng: RandomNumberGenerator, reserved: PackedByteArray) -> void:
	if biome.props.is_empty():
		return
	var noise := GridUtils.make_noise(rng.randi(), biome.vegetation_frequency)
	var rules := biome.props
	for i in GridUtils.shuffled_indices(map.cell_count(), rng):
		var c := map.cell(i)
		var cluster := smoothstep(0.5, 0.8, noise.get_noise_2d(c.x, c.y) * 0.5 + 0.5)
		var first := rng.randi_range(0, rules.size() - 1)
		for k in rules.size():
			var rule := rules[(first + k) % rules.size()]
			if rule == null or rule.prop == null:
				continue
			var chance := rule.density * lerpf(1.0, cluster * 2.0, rule.clustering)
			if rng.randf() >= chance:
				continue
			if _fits(map, rule.prop, c, reserved):
				_place(map, rule.prop, c)
				break


static func _fits(map: RoomMap, prop: PropDef, anchor: Vector2i, reserved: PackedByteArray) -> bool:
	if not map.in_bounds(anchor):
		return false
	var base := map.level_at(anchor)
	var on_water := prop.placement == PropDef.Placement.WATER
	for dy in prop.size.y:
		for dx in prop.size.x:
			var c := anchor + Vector2i(dx, -dy)
			if not map.in_bounds(c):
				return false
			var i := map.idx(c)
			if reserved[i] != 0 or map.occupied[i] != 0 or map.structure[i] != T.Structure.NONE or map.level[i] != base:
				return false
			if on_water:
				if map.terrain[i] != T.Terrain.WATER:
					return false
			elif map.terrain[i] != T.Terrain.LAND or map.wall[i] != 0 or map.is_cliff_face(c):
				return false
	return true


## Blocking props can close off little pockets of ground. Every pocket loses a prop that
## separates it from reachable ground, until all walkable ground is reachable.
static func _open_pockets(map: RoomMap) -> void:
	for _pass in map.props.size():
		var reached := map.reachable_from(map.center)
		var owner: Dictionary[int, int] = {}
		for k in map.props.size():
			var placed := map.props[k]
			if placed.prop.blocking:
				for dx in placed.prop.size.x:
					owner[map.idx(placed.cell + Vector2i(dx, 0))] = k
		# Best: a prop next to the pocket that also touches reached ground. Otherwise any
		# prop next to the pocket (the pocket then grows towards reached ground).
		var doomed := -1
		var fallback := -1
		for i in map.cell_count():
			if reached[i] != 0 or not map.is_walkable(map.cell(i)):
				continue
			for v in T.DIR_VECTORS:
				var n := map.cell(i) + v
				if not map.in_bounds(n) or not owner.has(map.idx(n)):
					continue
				if fallback < 0:
					fallback = owner[map.idx(n)]
				for w in T.DIR_VECTORS:
					var m := n + w
					if map.in_bounds(m) and reached[map.idx(m)] != 0:
						doomed = owner[map.idx(n)]
						break
				if doomed >= 0:
					break
			if doomed >= 0:
				break
		if doomed < 0:
			doomed = fallback
		if doomed < 0:
			return
		_remove(map, doomed)


static func _remove(map: RoomMap, index: int) -> void:
	var placed := map.props[index]
	for dy in placed.prop.size.y:
		for dx in placed.prop.size.x:
			var i := map.idx(placed.cell + Vector2i(dx, -dy))
			map.occupied[i] = 0
			map.blocked[i] = 0
	map.props.remove_at(index)


static func _place(map: RoomMap, prop: PropDef, anchor: Vector2i) -> void:
	for dy in prop.size.y:
		for dx in prop.size.x:
			var i := map.idx(anchor + Vector2i(dx, -dy))
			map.occupied[i] = 1
			if prop.blocking and dy == 0:
				map.blocked[i] = 1
	map.props.append(RoomMap.PlacedProp.new(prop, anchor))
