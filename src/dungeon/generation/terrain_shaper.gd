class_name TerrainShaper
extends RefCounted
## Raw terrain of a room: border with door corridors, elevation, ponds and rivers, then a
## cleanup that keeps every shape drawable by the autotile sets and readable in 2.5D:
## - plateaus and ponds are at least 2x2 (no 1-cell strips or single puddles);
## - a cliff never touches water (there is always a strip of ground below it);
## - level 2 never stands right next to level 0 (cliffs climb one level at a time);
## - tiny ponds, islands and plateaus are removed.

const T := preload("res://src/dungeon/dungeon_types.gd")
const MAX_CLEANUP_PASSES := 16
const MIN_ISLAND_CELLS := 4


## Border width at doors (and the length of door corridors).
static func border_depth(biome: BiomeData) -> int:
	return biome.border_thickness + biome.border_wobble


## Position of a door's center line along its side.
static func door_center(map: RoomMap, dir: int) -> int:
	return (map.size.y if T.is_horizontal(dir) else map.size.x) / 2


static func build_border(map: RoomMap, room: RoomData, config: DungeonConfig, biome: BiomeData,
		rng: RandomNumberGenerator) -> void:
	var depth := border_depth(biome)
	var noise := GridUtils.make_noise(rng.randi(), 0.18, 2)
	var door_reach := config.door_width / 2 + 2
	for i in map.cell_count():
		var c := map.cell(i)
		var dists := [c.y, map.size.x - 1 - c.x, map.size.y - 1 - c.y, c.x]
		for dir in 4:
			var along := c.y if T.is_horizontal(dir) else c.x
			var thickness := biome.border_thickness + roundi(
					(noise.get_noise_2d(along, dir * 64) * 0.5 + 0.5) * biome.border_wobble)
			# Constant width around doors so the corridor ends exactly at the interior.
			if room.neighbors.has(dir) and absi(along - door_center(map, dir)) <= door_reach:
				thickness = depth
			if dists[dir] < thickness:
				map.wall[i] = 1
				break
		if map.wall[i] != 0:
			match biome.border_style:
				T.BorderStyle.WATER:
					map.terrain[i] = T.Terrain.WATER
				T.BorderStyle.CLIFFS:
					map.level[i] = 1
	for dir in room.neighbors:
		_carve_door(map, dir, config, biome, depth)


## Marks a disc of interior cells as flat dry ground.
static func protect_disc(map: RoomMap, center: Vector2i, radius: float) -> void:
	var r := ceili(radius)
	for y in range(center.y - r, center.y + r + 1):
		for x in range(center.x - r, center.x + r + 1):
			var c := Vector2i(x, y)
			if map.in_bounds(c) and map.wall[map.idx(c)] == 0 and Vector2(c - center).length() <= radius + 0.5:
				map.keep_flat[map.idx(c)] = 1


static func shape(map: RoomMap, room: RoomData, config: DungeonConfig, biome: BiomeData,
		rng: RandomNumberGenerator, damping: float, flat: bool) -> void:
	if not flat:
		var calm := room.type != T.RoomType.COMBAT
		var elevation := biome.elevation_amount * (1.0 - damping)
		if room.type == T.RoomType.BOSS:
			elevation *= 0.5
		_raise_elevation(map, biome, rng, elevation)
		_fill_lakes(map, biome, rng, biome.lake_amount * (1.0 - damping) * (0.5 if calm else 1.0))
		if not calm and rng.randf() < biome.river_chance * (1.0 - damping):
			_carve_river(map, room, config, biome, rng)
	cleanup(map, biome)


## Repeats the shape rules until nothing changes. Returns false if it did not converge.
static func cleanup(map: RoomMap, biome: BiomeData) -> bool:
	for _pass in MAX_CLEANUP_PASSES:
		var changed := false
		changed = _apply_keep_flat(map) or changed
		changed = _enforce_margins(map) or changed
		for l: int in [2, 1]:
			changed = _open_level(map, l) or changed
			changed = _fill_level_gaps(map, l) or changed
		changed = _open_water(map) or changed
		changed = _open_land(map) or changed
		changed = _remove_small_water(map, biome.min_lake_cells) or changed
		changed = _remove_small_islands(map) or changed
		changed = _remove_small_plateaus(map, biome.min_plateau_cells) or changed
		if not changed:
			return true
	return false


## Lowering-only cleanup, used after a pass was cut through high ground. Never touches
## cells with structures.
static func settle(map: RoomMap, biome: BiomeData) -> void:
	for _pass in MAX_CLEANUP_PASSES:
		var changed := false
		changed = _enforce_margins(map) or changed
		for l: int in [2, 1]:
			changed = _open_level(map, l) or changed
		changed = _remove_small_plateaus(map, biome.min_plateau_cells) or changed
		if not changed:
			return


static func _carve_door(map: RoomMap, dir: int, config: DungeonConfig, biome: BiomeData, depth: int) -> void:
	var door := RoomMap.Door.new()
	door.dir = dir
	var horizontal := T.is_horizontal(dir)
	var inward := -T.DIR_VECTORS[dir]
	var along_axis := Vector2i(0, 1) if horizontal else Vector2i(1, 0)
	var center := door_center(map, dir)
	var edge_center: Vector2i
	match dir:
		T.Dir.NORTH:
			edge_center = Vector2i(center, 0)
		T.Dir.SOUTH:
			edge_center = Vector2i(center, map.size.y - 1)
		T.Dir.WEST:
			edge_center = Vector2i(0, center)
		_:
			edge_center = Vector2i(map.size.x - 1, center)
	var start := edge_center - along_axis * (config.door_width / 2)
	# Across a water border the door is a bridge, elsewhere a flat corridor.
	var water_border := biome.border_style == T.BorderStyle.WATER
	var bridge_width := mini(biome.bridge_width, config.door_width)
	var bridge_from := (config.door_width - bridge_width) / 2
	var bridge_type := T.Structure.BRIDGE_H if horizontal else T.Structure.BRIDGE_V
	for d in depth:
		for k in config.door_width:
			var c := start + along_axis * k + inward * d
			var i := map.idx(c)
			if water_border:
				if k < bridge_from or k >= bridge_from + bridge_width:
					continue
				map.terrain[i] = T.Terrain.WATER
				map.structure[i] = bridge_type
			else:
				map.terrain[i] = T.Terrain.LAND
				map.level[i] = 0
				map.keep_flat[i] = 1
			map.wall[i] = 0
			door.corridor.append(c)
			if d == 0:
				door.edge_cells.append(c)
	door.inner = edge_center + inward * depth
	map.doors.append(door)
	protect_disc(map, door.inner, 2.0)


static func _raise_elevation(map: RoomMap, biome: BiomeData, rng: RandomNumberGenerator, amount: float) -> void:
	if amount <= 0.0 or biome.max_level <= 0:
		return
	var noise := GridUtils.make_noise(rng.randi(), biome.elevation_frequency)
	var cells := PackedInt32Array()
	var values := PackedFloat32Array()
	for i in map.cell_count():
		if map.wall[i] == 0 and map.keep_flat[i] == 0 and map.terrain[i] == T.Terrain.LAND:
			var c := map.cell(i)
			cells.append(i)
			values.append(noise.get_noise_2d(c.x, c.y))
	if cells.is_empty():
		return
	var low := GridUtils.quantile(values, 1.0 - amount)
	var high_cells := PackedInt32Array()
	var high_values := PackedFloat32Array()
	for k in cells.size():
		if values[k] > low:
			map.level[cells[k]] = 1
			high_cells.append(cells[k])
			high_values.append(values[k])
	if biome.max_level < 2 or biome.high_ground_amount <= 0.0 or high_cells.is_empty():
		return
	var high := GridUtils.quantile(high_values, 1.0 - biome.high_ground_amount)
	for k in high_cells.size():
		if high_values[k] > high:
			map.level[high_cells[k]] = 2


static func _fill_lakes(map: RoomMap, biome: BiomeData, rng: RandomNumberGenerator, amount: float) -> void:
	if amount <= 0.0:
		return
	var noise := GridUtils.make_noise(rng.randi(), biome.lake_frequency)
	var cells := PackedInt32Array()
	var values := PackedFloat32Array()
	for i in map.cell_count():
		if map.wall[i] == 0:
			var c := map.cell(i)
			cells.append(i)
			values.append(noise.get_noise_2d(c.x, c.y))
	var threshold := GridUtils.quantile(values, 1.0 - amount)
	for k in cells.size():
		var i := cells[k]
		if values[k] > threshold and map.keep_flat[i] == 0 and _flat_around(map, map.cell(i)):
			map.terrain[i] = T.Terrain.WATER


static func _carve_river(map: RoomMap, room: RoomData, config: DungeonConfig, biome: BiomeData,
		rng: RandomNumberGenerator) -> void:
	var a_side := rng.randi_range(0, 3)
	var b_side := T.opposite(a_side)
	if rng.randf() < 0.4:
		b_side = (a_side + (1 if rng.randf() < 0.5 else 3)) % 4
	var a := _river_end(map, room, config, biome, a_side, rng)
	var b := _river_end(map, room, config, biome, b_side, rng)
	if a == Vector2.INF or b == Vector2.INF:
		return
	var ctrl := Vector2(rng.randf_range(0.3, 0.7) * map.size.x, rng.randf_range(0.3, 0.7) * map.size.y)
	var width := rng.randi_range(biome.river_width.x, maxi(biome.river_width.x, biome.river_width.y))
	# A little extra radius keeps diagonal stretches at least 2 cells wide, so the
	# sliver cleanup never cuts the river apart.
	var radius := width * 0.5 + 0.3
	var wiggle := GridUtils.make_noise(rng.randi(), 0.08, 2)
	var length := a.distance_to(ctrl) + ctrl.distance_to(b)
	var steps := maxi(int(length * 3.0), 8)
	for s in steps + 1:
		var t := float(s) / steps
		var p := a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t)
		var tangent := (ctrl - a).lerp(b - ctrl, t).normalized()
		p += Vector2(-tangent.y, tangent.x) * wiggle.get_noise_1d(t * length) * 3.0
		_stamp_water(map, p, radius)


## Point just outside the given side, away from doors and corners. INF if none fits.
static func _river_end(map: RoomMap, room: RoomData, config: DungeonConfig, biome: BiomeData, side: int,
		rng: RandomNumberGenerator) -> Vector2:
	var length := map.size.y if T.is_horizontal(side) else map.size.x
	var margin := border_depth(biome) + 3
	if length - 1 - margin <= margin:
		return Vector2.INF
	var avoid := config.door_width / 2 + 4
	for _try in 16:
		var along := rng.randi_range(margin, length - 1 - margin)
		if room.neighbors.has(side) and absi(along - door_center(map, side)) <= avoid:
			continue
		match side:
			T.Dir.NORTH:
				return Vector2(along + 0.5, -1.0)
			T.Dir.SOUTH:
				return Vector2(along + 0.5, map.size.y + 1.0)
			T.Dir.WEST:
				return Vector2(-1.0, along + 0.5)
			_:
				return Vector2(map.size.x + 1.0, along + 0.5)
	return Vector2.INF


static func _stamp_water(map: RoomMap, p: Vector2, radius: float) -> void:
	var outer := radius + 1.0
	for y in range(floori(p.y - outer), ceili(p.y + outer) + 1):
		for x in range(floori(p.x - outer), ceili(p.x + outer) + 1):
			var c := Vector2i(x, y)
			if not map.in_bounds(c):
				continue
			var i := map.idx(c)
			if map.structure[i] != T.Structure.NONE:
				continue
			var d := (Vector2(c) + Vector2(0.5, 0.5)).distance_to(p)
			if d <= radius:
				if map.keep_flat[i] == 0:
					map.terrain[i] = T.Terrain.WATER
					map.level[i] = 0
			elif d <= outer and map.wall[i] != 0:
				# The river cuts a bank through a cliff border.
				map.level[i] = 0


static func _flat_around(map: RoomMap, c: Vector2i) -> bool:
	if map.level[map.idx(c)] != 0:
		return false
	for o in T.AROUND_8:
		var n := c + o
		if map.in_bounds(n) and map.level[map.idx(n)] != 0:
			return false
	return true


static func _apply_keep_flat(map: RoomMap) -> bool:
	var changed := false
	for i in map.cell_count():
		if map.keep_flat[i] != 0 and map.structure[i] == T.Structure.NONE \
				and (map.level[i] != 0 or map.terrain[i] != T.Terrain.LAND):
			map.level[i] = 0
			map.terrain[i] = T.Terrain.LAND
			changed = true
	return changed


static func _enforce_margins(map: RoomMap) -> bool:
	var to_ground := PackedInt32Array()
	var to_one := PackedInt32Array()
	for i in map.cell_count():
		var l := map.level[i]
		if l == 0 or map.structure[i] != T.Structure.NONE:
			continue
		if map.terrain[i] == T.Terrain.WATER:
			to_ground.append(i)
			continue
		var c := map.cell(i)
		var near_water := false
		var near_ground := false
		for o in T.AROUND_8:
			var n := c + o
			if not map.in_bounds(n):
				continue
			var ni := map.idx(n)
			near_water = near_water or map.terrain[ni] == T.Terrain.WATER
			near_ground = near_ground or map.level[ni] == 0
		if near_water:
			to_ground.append(i)
		elif l == 2 and near_ground:
			to_one.append(i)
	for i in to_ground:
		map.level[i] = 0
	for i in to_one:
		map.level[i] = 1
	return not (to_ground.is_empty() and to_one.is_empty())


## Lowers level-l cells that are not part of any 2x2 block of level >= l.
static func _open_level(map: RoomMap, l: int) -> bool:
	var lower := PackedInt32Array()
	for i in map.cell_count():
		if map.level[i] >= l and map.structure[i] == T.Structure.NONE and not _in_block(map, map.cell(i), l, false):
			lower.append(i)
	for i in lower:
		map.level[i] = l - 1
	return not lower.is_empty()


## Raises 1-cell gaps between two plateaus of level l.
static func _fill_level_gaps(map: RoomMap, l: int) -> bool:
	var raise := PackedInt32Array()
	for i in map.cell_count():
		if map.level[i] != l - 1 or map.terrain[i] != T.Terrain.LAND or map.keep_flat[i] != 0 \
				or map.structure[i] != T.Structure.NONE or map.wall[i] != 0:
			continue
		var c := map.cell(i)
		var horizontal := _level_at_least(map, c + Vector2i.LEFT, l) and _level_at_least(map, c + Vector2i.RIGHT, l)
		var vertical := _level_at_least(map, c + Vector2i.UP, l) and _level_at_least(map, c + Vector2i.DOWN, l)
		if not (horizontal or vertical) or not _in_block(map, c, l, true):
			continue
		var blocked := false
		for o in T.AROUND_8:
			var n := c + o
			if map.in_bounds(n):
				var ni := map.idx(n)
				blocked = blocked or map.terrain[ni] == T.Terrain.WATER or (l == 2 and map.level[ni] == 0)
		if not blocked:
			raise.append(i)
	for i in raise:
		map.level[i] = l
	return not raise.is_empty()


## Turns water cells that are not part of any 2x2 water block into ground.
static func _open_water(map: RoomMap) -> bool:
	var dry := PackedInt32Array()
	for i in map.cell_count():
		if map.terrain[i] == T.Terrain.WATER and map.structure[i] == T.Structure.NONE and not _in_water_block(map, map.cell(i)):
			dry.append(i)
	for i in dry:
		map.terrain[i] = T.Terrain.LAND
		map.level[i] = 0
		# A sliver of a water border becomes part of the interior.
		if map.wall[i] != 0:
			for v in T.DIR_VECTORS:
				var n := map.cell(i) + v
				if map.in_bounds(n) and map.wall[map.idx(n)] == 0 and map.terrain[map.idx(n)] == T.Terrain.LAND:
					map.wall[i] = 0
					break
	return not dry.is_empty()


## Floods 1-cell land strips and spikes between water. Only cells that end up inside a
## 2x2 water block are flooded, so this never fights _open_water.
static func _open_land(map: RoomMap) -> bool:
	var flood := PackedInt32Array()
	for i in map.cell_count():
		if map.terrain[i] != T.Terrain.LAND or map.level[i] != 0 or map.keep_flat[i] != 0 \
				or map.structure[i] != T.Structure.NONE:
			continue
		var c := map.cell(i)
		if not _in_land_block(map, c) and _in_water_block_if_flooded(map, c):
			flood.append(i)
	for i in flood:
		map.terrain[i] = T.Terrain.WATER
	return not flood.is_empty()


static func _remove_small_water(map: RoomMap, min_cells: int) -> bool:
	var mask := PackedByteArray()
	mask.resize(map.cell_count())
	for i in map.cell_count():
		mask[i] = 1 if map.terrain[i] == T.Terrain.WATER else 0
	var changed := false
	for comp in GridUtils.components(mask, map.size):
		if comp.size() >= min_cells or _touches_wall_or_structure(map, comp):
			continue
		for i in comp:
			map.terrain[i] = T.Terrain.LAND
			map.level[i] = 0
		changed = true
	return changed


static func _remove_small_islands(map: RoomMap) -> bool:
	var mask := PackedByteArray()
	mask.resize(map.cell_count())
	for i in map.cell_count():
		mask[i] = 1 if map.terrain[i] == T.Terrain.LAND else 0
	var changed := false
	for comp in GridUtils.components(mask, map.size):
		if comp.size() >= MIN_ISLAND_CELLS or _touches_wall_or_structure(map, comp):
			continue
		var protected := false
		for i in comp:
			protected = protected or map.keep_flat[i] != 0
		if protected:
			continue
		for i in comp:
			map.terrain[i] = T.Terrain.WATER
			map.level[i] = 0
		changed = true
	return changed


static func _remove_small_plateaus(map: RoomMap, min_cells: int) -> bool:
	var changed := false
	for l: int in [2, 1]:
		var mask := PackedByteArray()
		mask.resize(map.cell_count())
		for i in map.cell_count():
			mask[i] = 1 if map.level[i] >= l and map.wall[i] == 0 else 0
		for comp in GridUtils.components(mask, map.size):
			if comp.size() >= min_cells or _attached_to_high_wall(map, comp, l):
				continue
			var has_structure := false
			for i in comp:
				has_structure = has_structure or map.structure[i] != T.Structure.NONE
			if has_structure:
				continue
			for i in comp:
				map.level[i] = l - 1
			changed = true
	return changed


## True if c belongs to a 2x2 block of cells with level >= l. Cells outside the room count
## as matching. With assume_self, c itself is treated as matching.
static func _in_block(map: RoomMap, c: Vector2i, l: int, assume_self: bool) -> bool:
	for oy in [-1, 0]:
		for ox in [-1, 0]:
			var ok := true
			for dy in 2:
				for dx in 2:
					var n := c + Vector2i(ox + dx, oy + dy)
					if assume_self and n == c:
						continue
					if map.in_bounds(n) and map.level[map.idx(n)] < l:
						ok = false
			if ok:
				return true
	return false


static func _in_water_block(map: RoomMap, c: Vector2i) -> bool:
	return _in_terrain_block(map, c, T.Terrain.WATER, false)


static func _in_water_block_if_flooded(map: RoomMap, c: Vector2i) -> bool:
	return _in_terrain_block(map, c, T.Terrain.WATER, true)


static func _in_land_block(map: RoomMap, c: Vector2i) -> bool:
	return _in_terrain_block(map, c, T.Terrain.LAND, false)


## True if c belongs to a 2x2 block of the given terrain (cells outside the room match).
static func _in_terrain_block(map: RoomMap, c: Vector2i, terrain: int, assume_self: bool) -> bool:
	for oy in [-1, 0]:
		for ox in [-1, 0]:
			var ok := true
			for dy in 2:
				for dx in 2:
					var n := c + Vector2i(ox + dx, oy + dy)
					if assume_self and n == c:
						continue
					if map.in_bounds(n) and map.terrain[map.idx(n)] != terrain:
						ok = false
			if ok:
				return true
	return false


static func _level_at_least(map: RoomMap, c: Vector2i, l: int) -> bool:
	return map.in_bounds(c) and map.level[map.idx(c)] >= l


static func _touches_wall_or_structure(map: RoomMap, comp: PackedInt32Array) -> bool:
	for i in comp:
		if map.wall[i] != 0 or map.structure[i] != T.Structure.NONE:
			return true
	return false


static func _attached_to_high_wall(map: RoomMap, comp: PackedInt32Array, l: int) -> bool:
	for i in comp:
		var c := map.cell(i)
		for v in T.DIR_VECTORS:
			var n := c + v
			if map.in_bounds(n) and map.wall[map.idx(n)] != 0 and map.level[map.idx(n)] >= l:
				return true
	return false
