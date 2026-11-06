extends SceneTree
## Headless checks of the dungeon generator over many seeds and every biome.
## Run: godot --headless --path . -s res://tests/test_dungeon_generator.gd -- --seeds=40

const T := preload("res://src/dungeon/dungeon_types.gd")

var _failures := 0


func _init() -> void:
	var seeds := 40
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="):
			seeds = int(arg.get_slice("=", 1))
	var config: DungeonConfig = load("res://data/dungeon/default_dungeon.tres")
	for biome in BiomeData.load_all():
		_run_biome(config, biome, seeds)
	_check_determinism(config)
	if _failures == 0:
		print("ALL PASSED")
	else:
		print("FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _run_biome(config: DungeonConfig, biome: BiomeData, seeds: int) -> void:
	var rooms := 0
	var shops := 0
	var first_try := 0
	var flat := 0
	var with_stairs := 0
	var with_bridges := 0
	var total_usec := 0
	var max_usec := 0
	for s in seeds:
		var started := Time.get_ticks_usec()
		var dungeon := DungeonGenerator.generate(config, s, biome)
		var spent := Time.get_ticks_usec() - started
		total_usec += spent
		max_usec = maxi(max_usec, spent)
		if dungeon == null:
			_fail("%s seed %d: no dungeon" % [biome.id, s])
			continue
		_check_layout(dungeon, config, "%s seed %d" % [biome.id, s])
		rooms += dungeon.rooms.size()
		shops += int(dungeon.shop_index >= 0)
		for room in dungeon.rooms:
			if room.map == null:
				continue
			first_try += int(room.attempts == 1)
			flat += int(room.attempts == config.max_room_attempts)
			with_stairs += int(not room.map.stairs.is_empty())
			with_bridges += int(_has_inner_bridge(room.map))
	print("%-10s dungeons %d | rooms %d | shops %d%% | first try %d%% | flat fallback %d | stairs in %d%% | bridges in %d%% | avg %.0f ms, max %.0f ms" % [
		biome.id, seeds, rooms, roundi(100.0 * shops / seeds), roundi(100.0 * first_try / maxi(rooms, 1)), flat,
		roundi(100.0 * with_stairs / maxi(rooms, 1)), roundi(100.0 * with_bridges / maxi(rooms, 1)),
		total_usec / 1000.0 / seeds, max_usec / 1000.0])


func _check_layout(dungeon: DungeonData, config: DungeonConfig, label: String) -> void:
	var count := dungeon.rooms.size()
	if count < config.min_rooms or count > config.max_rooms:
		_fail("%s: %d rooms" % [label, count])
	var by_type: Dictionary[int, int] = {}
	var max_depth := 0
	for room in dungeon.rooms:
		by_type[room.type] = by_type.get(room.type, 0) + 1
		max_depth = maxi(max_depth, room.depth)
		if room.depth < 0:
			_fail("%s: room %d is not connected" % [label, room.index])
		for dir in room.neighbors:
			var other := dungeon.rooms[room.neighbors[dir]]
			if other.grid_pos - room.grid_pos != T.DIR_VECTORS[dir] or other.neighbors.get(T.opposite(dir), -1) != room.index:
				_fail("%s: bad link %d -> %d" % [label, room.index, other.index])
		if room.map == null:
			_fail("%s: room %d has no map" % [label, room.index])
			continue
		if room.map.doors.size() != room.neighbors.size():
			_fail("%s: room %d has %d doors for %d links" % [label, room.index, room.map.doors.size(), room.neighbors.size()])
		for dir in room.neighbors:
			if room.map.door(dir) == null:
				_fail("%s: room %d misses the %s door" % [label, room.index, T.dir_name(dir)])
		var errors := RoomValidator.validate(room.map)
		if not errors.is_empty():
			_fail("%s: room %d (%s): %s" % [label, room.index, T.room_type_name(room.type), ", ".join(errors)])
	if by_type.get(T.RoomType.START, 0) != 1 or dungeon.rooms[0].type != T.RoomType.START:
		_fail("%s: start room missing" % label)
	if by_type.get(T.RoomType.BOSS, 0) != 1:
		_fail("%s: %d boss rooms" % [label, by_type.get(T.RoomType.BOSS, 0)])
	if by_type.get(T.RoomType.SHOP, 0) > 1:
		_fail("%s: several shops" % label)
	var boss := dungeon.rooms[dungeon.boss_index]
	if boss.type != T.RoomType.BOSS or boss.neighbors.size() != 1 or boss.depth != max_depth:
		_fail("%s: boss is not the farthest dead end" % label)
	if dungeon.shop_index >= 0:
		var shop := dungeon.rooms[dungeon.shop_index]
		if shop.type != T.RoomType.SHOP or shop.neighbors.size() != 1:
			_fail("%s: shop is not a dead end" % label)


func _check_determinism(config: DungeonConfig) -> void:
	for biome in BiomeData.load_all():
		var a := DungeonGenerator.generate(config, 777, biome)
		var b := DungeonGenerator.generate(config, 777, biome)
		for i in a.rooms.size():
			if a.rooms[i].map.checksum() != b.rooms[i].map.checksum():
				_fail("%s: seed 777 is not deterministic (room %d)" % [biome.id, i])


## A bridge built inside the room (not a door bridge across a water border).
func _has_inner_bridge(map: RoomMap) -> bool:
	for i in map.cell_count():
		if map.wall[i] == 0 and map.is_bridge(map.cell(i)):
			var on_door := false
			for door in map.doors:
				on_door = on_door or door.corridor.has(map.cell(i))
			if not on_door:
				return true
	return false


func _fail(message: String) -> void:
	_failures += 1
	if _failures <= 30:
		printerr(message)
