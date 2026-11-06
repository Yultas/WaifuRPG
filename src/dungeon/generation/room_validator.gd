class_name RoomValidator
extends RefCounted
## Invariants every generated room must satisfy. The generator rejects attempts that
## break them; tests run the same checks. Returns readable errors, empty when valid.

const T := preload("res://src/dungeon/dungeon_types.gd")
## Share of the interior that must be reachable from the center.
const MIN_OPEN_RATIO := 0.3
const MAX_ERRORS := 8


static func validate(map: RoomMap) -> PackedStringArray:
	var errors := PackedStringArray()
	_check_reachability(map, errors)
	_check_shapes(map, errors)
	_check_bridges(map, errors)
	_check_stairs(map, errors)
	_check_props(map, errors)
	_check_roads(map, errors)
	return errors


static func _check_reachability(map: RoomMap, errors: PackedStringArray) -> void:
	var reached := map.reachable_from(map.center)
	for k in map.key_cells():
		if reached[map.idx(k)] == 0:
			errors.append("key cell %s unreachable from center %s" % [k, map.center])
	for door in map.doors:
		for c in door.edge_cells:
			if reached[map.idx(c)] == 0:
				errors.append("door %s edge %s unreachable" % [T.dir_name(door.dir), c])
	var interior := 0
	var open := 0
	var stranded := 0
	for i in map.cell_count():
		if map.wall[i] == 0:
			interior += 1
			open += reached[i]
		if reached[i] == 0 and map.is_walkable(map.cell(i)):
			stranded += 1
	if stranded > 0:
		errors.append("%d walkable cells cannot be reached from the center" % stranded)
	if interior > 0 and float(open) / interior < MIN_OPEN_RATIO:
		errors.append("only %d%% of the interior is reachable" % roundi(100.0 * open / interior))


static func _check_shapes(map: RoomMap, errors: PackedStringArray) -> void:
	for i in map.cell_count():
		if errors.size() >= MAX_ERRORS:
			return
		var c := map.cell(i)
		var l := map.level[i]
		if map.terrain[i] == T.Terrain.WATER:
			if l != 0:
				errors.append("water above ground level at %s" % c)
			if map.structure[i] == T.Structure.NONE and not _block(map, c, func(n: Vector2i) -> bool: return map.is_water(n)):
				errors.append("water sliver at %s" % c)
			continue
		if l == 0:
			continue
		for k in range(1, l + 1):
			if not _block(map, c, func(n: Vector2i) -> bool: return map.level_at(n) >= k):
				errors.append("level-%d sliver at %s" % [k, c])
		for o in T.AROUND_8:
			var n := c + o
			if not map.in_bounds(n):
				continue
			if map.is_water(n):
				errors.append("cliff at %s touches water" % c)
			elif l == 2 and map.level_at(n) == 0:
				errors.append("level 2 next to level 0 at %s" % c)


## True if c is part of a 2x2 block where every in-room cell passes the test.
static func _block(map: RoomMap, c: Vector2i, test: Callable) -> bool:
	for oy in [-1, 0]:
		for ox in [-1, 0]:
			var ok := true
			for dy in 2:
				for dx in 2:
					var n := c + Vector2i(ox + dx, oy + dy)
					if map.in_bounds(n) and not test.call(n):
						ok = false
			if ok:
				return true
	return false


static func _check_bridges(map: RoomMap, errors: PackedStringArray) -> void:
	for i in map.cell_count():
		var s := map.structure[i]
		if s != T.Structure.BRIDGE_H and s != T.Structure.BRIDGE_V:
			continue
		var c := map.cell(i)
		if map.terrain[i] != T.Terrain.WATER:
			errors.append("bridge on land at %s" % c)
		var axis := [Vector2i.LEFT, Vector2i.RIGHT] if s == T.Structure.BRIDGE_H else [Vector2i.UP, Vector2i.DOWN]
		for v: Vector2i in axis:
			var n := c + v
			if not map.in_bounds(n) or map.structure[map.idx(n)] == s:
				continue
			if not map.is_land(n) or map.level_at(n) != 0 or not map.is_walkable(n):
				errors.append("bridge at %s ends on a bad cell %s" % [c, n])


static func _check_stairs(map: RoomMap, errors: PackedStringArray) -> void:
	for top in map.stairs:
		if not TerrainConnector.stairs_intact(map, top):
			errors.append("broken stairs at %s" % top)


## Roads lie on flat dry ground, free of props, with their level all around.
static func _check_roads(map: RoomMap, errors: PackedStringArray) -> void:
	for i in map.cell_count():
		if map.road[i] == 0:
			continue
		var c := map.cell(i)
		var ok := map.terrain[i] == T.Terrain.LAND and map.structure[i] == T.Structure.NONE and map.occupied[i] == 0
		for o in T.AROUND_8:
			var n := c + o
			if map.in_bounds(n):
				ok = ok and map.terrain[map.idx(n)] == T.Terrain.LAND and map.level_at(n) == map.level[i]
		if not ok:
			errors.append("bad road cell at %s" % c)
			return


static func _check_props(map: RoomMap, errors: PackedStringArray) -> void:
	var cover := PackedByteArray()
	cover.resize(map.cell_count())
	for placed in map.props:
		var base := map.level_at(placed.cell)
		for dy in placed.prop.size.y:
			for dx in placed.prop.size.x:
				var c := placed.cell + Vector2i(dx, -dy)
				if not map.in_bounds(c):
					errors.append("prop %s out of bounds" % placed.prop.id)
					continue
				var i := map.idx(c)
				if cover[i] != 0:
					errors.append("props overlap at %s" % c)
				cover[i] = 1
				if map.level[i] != base or map.structure[i] != T.Structure.NONE:
					errors.append("prop %s on uneven or built cell %s" % [placed.prop.id, c])
				var wants_water := placed.prop.placement == PropDef.Placement.WATER
				if map.is_water(c) != wants_water:
					errors.append("prop %s on wrong terrain at %s" % [placed.prop.id, c])
				if placed.prop.blocking and dy == 0 and map.path[i] != 0:
					errors.append("prop %s blocks the path at %s" % [placed.prop.id, c])
