extends SceneTree
## Physics walk test on real collision bodies:
## - a hero driven along the grid path from the room center leaves through every door;
## - a hero on a cliff edge cannot step down, a hero below cannot climb up.
## Run: godot --headless --fixed-fps 60 --path . -s res://tests/test_room_walk.gd -- --seeds=3
## (--fixed-fps makes physics run as fast as possible instead of in real time.)

const T := preload("res://src/dungeon/dungeon_types.gd")
const HERO_SPEED := 8.0
const ARRIVE_DISTANCE := 0.35
const STUCK_SECONDS := 2.0
const PUSH_SECONDS := 1.0
const CLIFF_CHECKS_PER_ROOM := 4

var _failures := 0
var _walks := 0
var _cliff_checks := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var seeds := 3
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="):
			seeds = int(arg.get_slice("=", 1))
	var config: DungeonConfig = load("res://data/dungeon/default_dungeon.tres")
	for biome in BiomeData.load_all():
		for s in seeds:
			var dungeon := DungeonGenerator.generate(config, 1000 + s, biome)
			for room in dungeon.rooms:
				await _test_room(room, biome, "%s seed %d room %d (%s)" % [biome.id, 1000 + s, room.index, T.room_type_name(room.type)])
	print("walks %d, cliff checks %d" % [_walks, _cliff_checks])
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_room(room: RoomData, biome: BiomeData, label: String) -> void:
	var map := room.map
	var ppm := WorldUnits.PIXELS_PER_METER
	var world := Node2D.new()
	root.add_child(world)
	world.add_child(RoomCollision.build_2d(map, ppm, biome.tile_theme.cliff_face_depth))
	var hero := TestHero.new()
	hero.use_keyboard = false
	hero.speed = HERO_SPEED
	world.add_child(hero)
	await physics_frame

	for door in map.doors:
		hero.enter_room(map, ppm, map.center)
		await physics_frame
		var edge := door.edge_cells[door.edge_cells.size() / 2]
		var path := map.find_path(map.center, edge)
		if path.is_empty():
			_fail("%s: no grid path to the %s door" % [label, T.dir_name(door.dir)])
			continue
		# One more cell outside the room: the hero must be able to walk out.
		path.append(edge + T.DIR_VECTORS[door.dir])
		var stuck_at := await _follow(hero, path)
		if stuck_at >= 0:
			_fail("%s: stuck on the way to the %s door near cell %s (hero at %s m, level %d)" % [
				label, T.dir_name(door.dir), path[stuck_at], hero.meters(), hero.level])
		_walks += 1

	await _check_cliffs(map, hero, label)
	world.queue_free()
	await process_frame


## Steers the hero from cell center to cell center. Returns the index of the cell it got
## stuck on, or -1 when it reached the end.
func _follow(hero: TestHero, path: Array[Vector2i]) -> int:
	var i := 1
	var best := INF
	var stuck := 0.0
	while i < path.size():
		var target := (Vector2(path[i]) + Vector2(0.5, 0.5)) * WorldUnits.CELL_SIZE
		if (target - hero.meters()).length() < ARRIVE_DISTANCE:
			i += 1
			best = INF
			stuck = 0.0
			continue
		hero.steer = (target - hero.meters()).normalized()
		await physics_frame
		var d := (target - hero.meters()).length()
		if d < best - 0.01:
			best = d
			stuck = 0.0
		else:
			stuck += 1.0 / Engine.physics_ticks_per_second
			if stuck > STUCK_SECONDS:
				hero.steer = Vector2.ZERO
				return i
	hero.steer = Vector2.ZERO
	return -1


## Cliffs are one-way walls in both directions: no stepping down, no climbing up.
func _check_cliffs(map: RoomMap, hero: TestHero, label: String) -> void:
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
		var upper := map.level_at(top)
		var lower := map.level_at(below)

		# On the upper level, standing on the face top, pushing south.
		hero.enter_room(map, hero.pixels_per_meter, top)
		hero.position.y -= 0.35 * WorldUnits.CELL_SIZE * hero.pixels_per_meter
		await _push(hero, Vector2.DOWN)
		if hero.level != upper or hero.cell().y > top.y:
			_fail("%s: hero dropped off the cliff at %s (now cell %s, level %d)" % [label, top, hero.cell(), hero.level])

		# On the lower level, below the face, pushing north.
		hero.enter_room(map, hero.pixels_per_meter, below)
		await _push(hero, Vector2.UP)
		if hero.level != lower or hero.cell().y < below.y:
			_fail("%s: hero climbed the cliff at %s (now cell %s, level %d)" % [label, top, hero.cell(), hero.level])


func _push(hero: TestHero, dir: Vector2) -> void:
	hero.steer = dir
	for _frame in int(PUSH_SECONDS * Engine.physics_ticks_per_second):
		await physics_frame
	hero.steer = Vector2.ZERO


func _fail(message: String) -> void:
	_failures += 1
	if _failures <= 30:
		printerr(message)
