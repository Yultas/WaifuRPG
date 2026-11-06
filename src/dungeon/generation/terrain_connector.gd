class_name TerrainConnector
extends RefCounted
## Links walkable regions of a room: first until every key cell (doors, center) is
## reachable, then until every walkable cell is.
## - bridges: straight spans over water between two level-0 shores;
## - stairs: 2x2 blocks on a straight south-facing cliff (the tiles climb north);
## - passes: as a last resort, a 3-wide cut through high ground down to the lower level.
## Each step picks the cheapest link out of the region of the center. Regions that
## cannot be linked are retired (lowered or flooded), so no ground is left unreachable.

const T := preload("res://src/dungeon/dungeon_types.gd")
const MAX_LINKS := 24
const MAX_CUT := 10
## Extra cost of a link that leads to a region without key cells.
const DETOUR_COST := 6.0
## Smaller unreachable regions are retired rather than linked.
const MIN_LINKED_CELLS := 12
const MAX_SETTLE_STEPS := 80


class Link:
	enum Kind { BRIDGE, STAIRS, CUT }
	var kind: Kind
	var origin := Vector2i.ZERO
	var dir := 0
	var span := 0
	var target := -1
	var cost := 0.0


static func connect_keys(map: RoomMap, biome: BiomeData, rng: RandomNumberGenerator) -> bool:
	var keys := map.key_cells()
	for _i in MAX_LINKS:
		var labels := map.compute_regions()
		var main := labels[map.idx(map.center)]
		if main < 0:
			return false
		var key_regions: Dictionary[int, bool] = {}
		for k in keys:
			var r := labels[map.idx(k)]
			if r < 0:
				return false
			if r != main:
				key_regions[r] = true
		if key_regions.is_empty():
			return true
		var links := _collect(map, biome, labels, main, key_regions)
		var best: Link = null
		var best_cost := INF
		for link in links:
			var cost := link.cost + rng.randf() * 1.5 + (0.0 if key_regions.has(link.target) else DETOUR_COST)
			if cost < best_cost:
				best_cost = cost
				best = link
		if best == null:
			return false
		_apply(map, biome, best)
	return false


## Makes every walkable cell reachable from the center (run after connect_keys).
## Each step links the cheapest unreachable region of at least MIN_LINKED_CELLS. A region
## that is smaller, or that no link can reach, is retired instead: high ground is lowered
## one level, low ground is flooded. Returns false if the room could not be settled.
static func connect_everything(map: RoomMap, biome: BiomeData, rng: RandomNumberGenerator) -> bool:
	for _i in MAX_SETTLE_STEPS:
		var labels := map.compute_regions()
		var main := labels[map.idx(map.center)]
		if main < 0:
			return false
		var regions: Dictionary[int, PackedInt32Array] = {}
		for i in labels.size():
			if labels[i] >= 0 and labels[i] != main:
				if not regions.has(labels[i]):
					regions[labels[i]] = PackedInt32Array()
				regions[labels[i]].append(i)
		if regions.is_empty():
			return true
		# Tiny pieces are not worth a bridge or stairs: retire them all at once.
		var retired := false
		var smallest := -1
		for r in regions:
			if regions[r].size() < MIN_LINKED_CELLS:
				_retire(map, regions[r])
				retired = true
			elif smallest < 0 or regions[r].size() < regions[smallest].size():
				smallest = r
		if retired:
			_settle(map, biome)
			continue
		var best: Link = null
		var best_cost := INF
		for link in _collect(map, biome, labels, main, regions):
			var cost := link.cost + rng.randf() * 1.5
			if regions.has(link.target) and cost < best_cost:
				best_cost = cost
				best = link
		if best != null:
			_apply(map, biome, best)
		else:
			_retire(map, regions[smallest])
			_settle(map, biome)
	return false


## Removes an unreachable region (call TerrainShaper.settle afterwards). High ground goes
## one level down and may merge with the ground around it. Low ground turns into water
## where that makes a proper pond (every flooded cell in a 2x2 water block); the rest
## becomes part of the room border.
static func _retire(map: RoomMap, cells: PackedInt32Array) -> void:
	var level := map.level[cells[0]]
	if level > 0:
		for i in cells:
			if map.structure[i] == T.Structure.NONE:
				map.level[i] = level - 1
		return
	var flooded := PackedInt32Array()
	for i in cells:
		if map.structure[i] == T.Structure.NONE:
			map.terrain[i] = T.Terrain.WATER
			flooded.append(i)
	var changed := true
	while changed:
		changed = false
		for i in flooded:
			if map.terrain[i] == T.Terrain.WATER and not _in_water_block(map, map.cell(i)):
				map.terrain[i] = T.Terrain.LAND
				map.wall[i] = 1
				changed = true


static func _in_water_block(map: RoomMap, c: Vector2i) -> bool:
	for oy in [-1, 0]:
		for ox in [-1, 0]:
			var ok := true
			for dy in 2:
				for dx in 2:
					var n := c + Vector2i(ox + dx, oy + dy)
					if map.in_bounds(n) and not map.is_water(n):
						ok = false
			if ok:
				return true
	return false


## Bridges and stairs out of the main region. Passes are only searched (they are slow to
## find) when no bridge or stairs reaches one of the wanted regions.
static func _collect(map: RoomMap, biome: BiomeData, labels: PackedInt32Array, main: int, wanted: Dictionary) -> Array[Link]:
	var links: Array[Link] = []
	for i in map.cell_count():
		if labels[i] != main:
			continue
		for dir in 4:
			var bridge := _bridge_from(map, biome, labels, main, map.cell(i), dir)
			if bridge != null:
				links.append(bridge)
	_collect_stairs(map, labels, main, links)
	for link in links:
		if wanted.has(link.target):
			return links
	for i in map.cell_count():
		if labels[i] < 0:
			continue
		for dir in 4:
			# Passes may start on either side, so main can also be the lower region's target.
			var cut := _cut_from(map, labels, main, map.cell(i), dir)
			if cut != null:
				links.append(cut)
	return links


static func _bridge_from(map: RoomMap, biome: BiomeData, labels: PackedInt32Array, main: int, a: Vector2i, dir: int) -> Link:
	if map.level_at(a) != 0 or not map.is_land(a) or map.structure[map.idx(a)] != T.Structure.NONE:
		return null
	var v := T.DIR_VECTORS[dir]
	var span := 0
	var c := a + v
	while span <= biome.max_bridge_length and map.in_bounds(c) and _open_water(map, c):
		span += 1
		c += v
	if span == 0 or span > biome.max_bridge_length or not map.in_bounds(c):
		return null
	var target := labels[map.idx(c)]
	if target < 0 or target == main or not _shore(map, c):
		return null
	var side := Vector2i(-v.y, v.x)
	for lane in range(1, biome.bridge_width):
		if not _bridge_lane_ok(map, a + side * lane, v, span):
			return null
	# Bridges hugging a shore look odd; prefer spans with water on both sides.
	var hugging := 0
	for j in range(1, span + 1):
		for s in [a - side + v * j, a + side * biome.bridge_width + v * j]:
			if map.in_bounds(s) and not map.is_water(s):
				hugging += 1
	var link := Link.new()
	link.kind = Link.Kind.BRIDGE
	link.origin = a
	link.dir = dir
	link.span = span
	link.target = target
	link.cost = span + 1.0 + hugging * 2.0
	return link


static func _bridge_lane_ok(map: RoomMap, start: Vector2i, v: Vector2i, span: int) -> bool:
	if not map.in_bounds(start) or not _shore(map, start):
		return false
	for j in range(1, span + 1):
		var c := start + v * j
		if not map.in_bounds(c) or not _open_water(map, c):
			return false
	var end := start + v * (span + 1)
	return map.in_bounds(end) and _shore(map, end)


static func _open_water(map: RoomMap, c: Vector2i) -> bool:
	var i := map.idx(c)
	return map.terrain[i] == T.Terrain.WATER and map.wall[i] == 0 and map.structure[i] == T.Structure.NONE


## Walkable level-0 ground without structures: a valid bridge end.
static func _shore(map: RoomMap, c: Vector2i) -> bool:
	var i := map.idx(c)
	return map.is_walkable(c) and map.terrain[i] == T.Terrain.LAND and map.level[i] == 0 \
			and map.structure[i] == T.Structure.NONE


## Stairs occupy (x..x+1, y..y+1): the top row is the cliff edge of level u, the bottom
## row is level u-1. The cliff must run straight one cell further on each side, with
## plateau above and room to approach below.
static func _collect_stairs(map: RoomMap, labels: PackedInt32Array, main: int, links: Array[Link]) -> void:
	for y in range(1, map.size.y - 2):
		for x in range(1, map.size.x - 2):
			var top := Vector2i(x, y)
			var upper := map.level_at(top)
			if upper == 0 or not stairs_fit(map, top):
				continue
			var rt := labels[map.idx(top)]
			var rb := labels[map.idx(top + Vector2i.DOWN)]
			if rt < 0 or rb < 0 or rt == rb or (rt != main and rb != main):
				continue
			var link := Link.new()
			link.kind = Link.Kind.STAIRS
			link.origin = top
			link.target = rb if rt == main else rt
			link.cost = 3.0
			links.append(link)


## Lowering-only cleanup after a terrain change, then drops stairs it bent.
static func _settle(map: RoomMap, biome: BiomeData) -> void:
	TerrainShaper.settle(map, biome)
	_drop_broken_stairs(map)


## True if the stairs placed at `top` still have the shape stairs_fit asked for.
static func stairs_intact(map: RoomMap, top: Vector2i) -> bool:
	var upper := map.level_at(top)
	if upper == 0:
		return false
	for dx in range(-1, 3):
		var inner := dx == 0 or dx == 1
		var expected := T.Structure.STAIRS if inner else T.Structure.NONE
		var row := [top + Vector2i(dx, -1), top + Vector2i(dx, 0), top + Vector2i(dx, 1)]
		if map.level_at(row[0]) != upper or map.level_at(row[1]) != upper or map.level_at(row[2]) != upper - 1:
			return false
		if map.structure[map.idx(row[1])] != expected or map.structure[map.idx(row[2])] != expected:
			return false
		if inner and map.level_at(top + Vector2i(dx, 2)) != upper - 1:
			return false
	return true


## Terrain changes (passes, retired regions) can bend the cliff around stairs. Such stairs
## are removed; the regions they joined get linked again on a later step.
static func _drop_broken_stairs(map: RoomMap) -> void:
	for k in range(map.stairs.size() - 1, -1, -1):
		var top := map.stairs[k]
		if stairs_intact(map, top):
			continue
		for o: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			map.structure[map.idx(top + o)] = T.Structure.NONE
		map.stairs.remove_at(k)


static func stairs_fit(map: RoomMap, top: Vector2i) -> bool:
	var upper := map.level_at(top)
	var lower := upper - 1
	for dx in range(-1, 3):
		var inner := dx == 0 or dx == 1
		# Plateau above the stairs.
		if not _plain(map, top + Vector2i(dx, -1), upper, inner):
			return false
		# The cliff edge row.
		if not _plain(map, top + Vector2i(dx, 0), upper, inner):
			return false
		# Ground below the cliff.
		if not _plain(map, top + Vector2i(dx, 1), lower, inner):
			return false
		# Approach below the stairs.
		if inner and not _plain(map, top + Vector2i(dx, 2), lower, true):
			return false
	return true


## Dry, structure-free cell on the given level. `open` also requires it to be walkable.
static func _plain(map: RoomMap, c: Vector2i, l: int, open: bool) -> bool:
	if not map.in_bounds(c):
		return false
	var i := map.idx(c)
	if map.level[i] != l or map.terrain[i] != T.Terrain.LAND or map.structure[i] != T.Structure.NONE:
		return false
	return not open or map.is_walkable(c)


## A straight run of higher ground from `a` to a cell of another region on a's level.
static func _cut_from(map: RoomMap, labels: PackedInt32Array, main: int, a: Vector2i, dir: int) -> Link:
	var base := map.level_at(a)
	var v := T.DIR_VECTORS[dir]
	var span := 0
	var c := a + v
	while span < MAX_CUT and map.in_bounds(c) and map.level_at(c) > base and _cuttable(map, c):
		span += 1
		c += v
	if span == 0 or span >= MAX_CUT or not map.in_bounds(c):
		return null
	var origin_region := labels[map.idx(a)]
	var end_region := labels[map.idx(c)]
	if end_region < 0 or end_region == origin_region or map.level_at(c) != base:
		return null
	if origin_region != main and end_region != main:
		return null
	var target := end_region if origin_region == main else origin_region
	var side := Vector2i(-v.y, v.x)
	for lane: int in [-1, 1]:
		for j in range(0, span + 2):
			var s := a + side * lane + v * j
			if not map.in_bounds(s) or not _cuttable(map, s):
				return null
	var link := Link.new()
	link.kind = Link.Kind.CUT
	link.origin = a
	link.dir = dir
	link.span = span
	link.target = target
	link.cost = 6.0 + span * 1.5
	return link


static func _cuttable(map: RoomMap, c: Vector2i) -> bool:
	var i := map.idx(c)
	return map.terrain[i] == T.Terrain.LAND and map.wall[i] == 0 and map.structure[i] == T.Structure.NONE


static func _apply(map: RoomMap, biome: BiomeData, link: Link) -> void:
	match link.kind:
		Link.Kind.BRIDGE:
			var v := T.DIR_VECTORS[link.dir]
			var side := Vector2i(-v.y, v.x)
			var type := T.Structure.BRIDGE_H if T.is_horizontal(link.dir) else T.Structure.BRIDGE_V
			for lane in biome.bridge_width:
				for j in range(1, link.span + 1):
					map.structure[map.idx(link.origin + side * lane + v * j)] = type
		Link.Kind.STAIRS:
			for o: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				map.structure[map.idx(link.origin + o)] = T.Structure.STAIRS
			map.stairs.append(link.origin)
		Link.Kind.CUT:
			var base := map.level_at(link.origin)
			var v := T.DIR_VECTORS[link.dir]
			var side := Vector2i(-v.y, v.x)
			for lane: int in [-1, 0, 1]:
				for j in range(1, link.span + 1):
					var i := map.idx(link.origin + side * lane + v * j)
					map.level[i] = mini(map.level[i], base)
			_settle(map, biome)
