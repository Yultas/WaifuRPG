extends SceneTree
## Navigation mesh checks through the real NavigationServer2D on generated rooms:
## - the room center reaches every door over the navigation mesh (ordinary traversal);
## - across a cliff face the navigation mesh has no path exactly when the grid rules
##   (RoomMap.can_step) have none;
## - every stair block joins its upper and lower cell on the mesh.
## Every sampled navigation path must cross only cells and edges the grid allows.
## Run: godot --headless --path . -s res://tests/test_room_navigation.gd -- --seeds=3
## (no --fixed-fps: with it the navigation server never processes its command queue and
## the regions end up with no geometry on the map).

const T := preload("res://src/dungeon/dungeon_types.gd")

## Meters advanced per sample when a path is checked against the grid.
const SAMPLE_STEP := 0.05
## Points within this distance (pixels) of a cell boundary may belong to the cell on the
## other side: funnel paths follow polygon edges exactly along the seams, and a point on a
## seam must be attributed to a neighbouring walkable cell instead of failing the check.
const SEAM_EPS := 0.01
const CLIFF_CHECKS_PER_ROOM := 4

var _failures := 0
var _rooms := 0
var _door_paths := 0
var _cliff_checks := 0
var _stair_checks := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var seeds := 3
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="):
			seeds = int(arg.get_slice("=", 1))
	# Each room gets its own navigation map: on a shared map a region added right after
	# another was removed ends up with no geometry, and rooms share the same local
	# coordinates, so their meshes would falsely connect.
	var config: DungeonConfig = load("res://data/dungeon/default_dungeon.tres")
	for biome in BiomeData.load_all():
		for s in seeds:
			var dungeon := DungeonGenerator.generate(config, 1000 + s, biome)
			for room in dungeon.rooms:
				await _test_room(room.map, "%s seed %d room %d (%s)" % [biome.id, 1000 + s, room.index, T.room_type_name(room.type)])
	if _stair_checks == 0:
		_fail("no stair block was exercised: generate more seeds or check the stair rule")
	print("rooms %d | door paths %d | cliff checks %d | stair checks %d" % [_rooms, _door_paths, _cliff_checks, _stair_checks])
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_room(map: RoomMap, label: String) -> void:
	_rooms += 1
	var ppm := WorldUnits.PIXELS_PER_METER
	var world := Node2D.new()
	root.add_child(world)
	var nav := RoomNavigation.build_2d(map, ppm)
	world.add_child(nav)
	var nav_map := NavigationServer2D.map_create()
	NavigationServer2D.map_set_active(nav_map, true)
	nav.set_navigation_map(nav_map)
	await physics_frame

	# Ordinary traversal: the center reaches every door inner cell, exactly like the grid.
	var connected := false
	for door in map.doors:
		var grid_path := map.find_path(map.center, door.inner)
		if grid_path.is_empty():
			_fail("%s: no grid path to the %s door" % [label, T.dir_name(door.dir)])
			continue
		var nav_path := await _nav_path(nav_map, _cell_px(map.center, ppm), _cell_px(door.inner, ppm))
		if nav_path.is_empty():
			_fail("%s: no nav path to the %s door" % [label, T.dir_name(door.dir)])
			continue
		connected = true
		_door_paths += 1
		_check_path_on_grid(map, nav_path, ppm, label)

	# Stairs: both cells of every stair column must be joined through the shared edge.
	for top in map.stairs:
		var upper := top
		var lower := top + Vector2i.DOWN
		if not map.is_walkable(upper) or not map.is_walkable(lower):
			continue
		_stair_checks += 1
		var nav_path := await _nav_path(nav_map, _cell_px(upper, ppm), _cell_px(lower, ppm))
		if nav_path.is_empty():
			_fail("%s: stairs at %s do not connect the levels on the nav mesh" % [label, top])
		elif not map.can_step(upper, T.Dir.SOUTH):
			_fail("%s: stairs at %s are not a legal grid step" % [label, top])
		else:
			_check_path_on_grid(map, nav_path, ppm, label)

	if connected:
		await _check_cliffs(map, nav_map, ppm, label)

	world.queue_free()
	await process_frame
	NavigationServer2D.map_set_active(nav_map, false)
	NavigationServer2D.free_rid(nav_map)


## NavigationServer2D path with a sync wait: an empty result right after map_force_update
## can mean "not synced yet" as well as "no path". The map is only trustworthy once it has
## finished a few iterations, so wait for them (the first room after a long generation can
## take many frames) and only then trust an empty result.
func _nav_path(nav_map: RID, from_px: Vector2, to_px: Vector2) -> PackedVector2Array:
	for i in 60:
		NavigationServer2D.map_force_update(nav_map)
		if NavigationServer2D.map_get_iteration_id(nav_map) >= 2:
			var path := NavigationServer2D.map_get_path(nav_map, from_px, to_px, true)
			if not path.is_empty():
				return path
		await physics_frame
	return PackedVector2Array()


## Cliffs are one-way in both directions: the navigation mesh must agree with the grid —
## a path across the face exists exactly when RoomMap.find_path finds one (stairs
## elsewhere may legitimately connect the two levels).
func _check_cliffs(map: RoomMap, nav_map: RID, ppm: float, label: String) -> void:
	var checked := 0
	for i in map.cell_count():
		if checked >= CLIFF_CHECKS_PER_ROOM:
			return
		var top := map.cell(i)
		var below := top + Vector2i.DOWN
		if not map.is_cliff_face(top) or not map.is_walkable(top) or not map.is_walkable(below) \
				or map.structure[i] != T.Structure.NONE or map.structure[map.idx(below)] != T.Structure.NONE:
			continue
		checked += 1
		_cliff_checks += 1
		var grid_connected := not map.find_path(top, below).is_empty()
		var nav_connected := not (await _nav_path(nav_map, _cell_px(top, ppm), _cell_px(below, ppm))).is_empty()
		if nav_connected != grid_connected:
			_fail("%s: cliff at %s: grid connected %s but nav connected %s" % [label, top, grid_connected, nav_connected])


## Walks a navigation path in small samples and requires every entered cell to be walkable
## and every crossed cell edge to satisfy RoomMap.can_step: the mesh must never leak through
## cliffs, bridge sides, props or across levels. A path may pass exactly through a grid
## vertex between two diagonally adjacent cells; that is legal only when one of the two
## orthogonal grid routes around the vertex is fully crossable.
func _check_path_on_grid(map: RoomMap, path: PackedVector2Array, ppm: float, label: String) -> void:
	var step := SAMPLE_STEP * ppm
	var prev := Vector2i(-1, -1)
	for seg in path.size() - 1:
		var a := path[seg]
		var b := path[seg + 1]
		var samples := maxi(1, int(a.distance_to(b) / step))
		for k in samples + 1:
			var point := a.lerp(b, float(k) / samples)
			var cell := Vector2i(floori(point.x / ppm), floori(point.y / ppm))
			if not map.is_walkable(cell):
				# A funnel path may hug a polygon edge exactly on a cell seam; attribute
				# such a point to a neighbouring walkable cell instead of failing.
				var alternatives := _cells_near(point, ppm)
				if prev != Vector2i(-1, -1) and alternatives.has(prev) and map.is_walkable(prev):
					cell = prev
				else:
					var replaced := false
					for alt in alternatives:
						if map.is_walkable(alt):
							cell = alt
							replaced = true
							break
					if not replaced:
						_fail("%s: nav path enters unwalkable cell %s" % [label, cell])
						return
			if prev != Vector2i(-1, -1) and cell != prev:
				if not _is_legal_transition(map, prev, cell):
					_fail("%s: nav path crosses forbidden edge %s -> %s" % [label, prev, cell])
					return
			prev = cell


## Grid legality of one sampling transition: a 4-neighbour step needs can_step; a diagonal
## vertex pass needs one of the two orthogonal detours to be fully crossable.
func _is_legal_transition(map: RoomMap, from: Vector2i, to: Vector2i) -> bool:
	var delta := to - from
	if absi(delta.x) + absi(delta.y) == 1:
		return _can_step_dir(map, from, delta)
	if absi(delta.x) == 1 and absi(delta.y) == 1:
		return (_can_step_dir(map, from, Vector2i(delta.x, 0)) and _can_step_dir(map, from + Vector2i(delta.x, 0), Vector2i(0, delta.y))) \
			or (_can_step_dir(map, from, Vector2i(0, delta.y)) and _can_step_dir(map, from + Vector2i(0, delta.y), Vector2i(delta.x, 0)))
	return false


## Cells whose closed rect a boundary-near point may belong to: the point can sit on a
## seam, within SEAM_EPS of the next cell over.
func _cells_near(point: Vector2, ppm: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for x in [floori((point.x - SEAM_EPS) / ppm), floori((point.x + SEAM_EPS) / ppm)]:
		for y in [floori((point.y - SEAM_EPS) / ppm), floori((point.y + SEAM_EPS) / ppm)]:
			var c := Vector2i(x, y)
			if not out.has(c):
				out.append(c)
	return out


func _can_step_dir(map: RoomMap, from: Vector2i, delta: Vector2i) -> bool:
	for dir in 4:
		if T.DIR_VECTORS[dir] == delta:
			return map.can_step(from, dir)
	return false


func _cell_px(c: Vector2i, ppm: float) -> Vector2:
	return WorldUnits.cell_to_world(c) * ppm


func _fail(message: String) -> void:
	_failures += 1
	if _failures <= 30:
		printerr(message)
