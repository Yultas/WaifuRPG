class_name RoomGenerator
extends RefCounted
## Room pipeline: border -> terrain -> connectivity -> decoration -> validation.
## A failed attempt is retried with a new sub-seed and calmer terrain. The last attempt is
## flat (no elevation or water inside), which always connects.

const T := preload("res://src/dungeon/dungeon_types.gd")


static func generate(room: RoomData, config: DungeonConfig, biome: BiomeData) -> RoomMap:
	var attempts := maxi(config.max_room_attempts, 1)
	var last_errors := PackedStringArray()
	for attempt in attempts:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([room.room_seed, attempt])
		var flat := attempts > 1 and attempt == attempts - 1
		var damping := float(attempt) / attempts
		var map := build(room, config, biome, rng, damping, flat)
		last_errors = RoomValidator.validate(map) if map != null else PackedStringArray(["key cells not connected"])
		if last_errors.is_empty():
			room.attempts = attempt + 1
			return map
	push_error("RoomGenerator: room %d failed: %s" % [room.index, ", ".join(last_errors)])
	return null


## One attempt. Returns null if the key cells could not be connected.
static func build(room: RoomData, config: DungeonConfig, biome: BiomeData, rng: RandomNumberGenerator,
		damping: float, flat: bool) -> RoomMap:
	var map := RoomMap.new(room.size)
	TerrainShaper.build_border(map, room, config, biome, rng)
	if room.type != T.RoomType.COMBAT:
		TerrainShaper.protect_disc(map, room.size / 2, _flat_center_radius(room))
	TerrainShaper.shape(map, room, config, biome, rng, damping, flat)
	map.center = map.nearest_open_land(room.size / 2)
	if not TerrainConnector.connect_keys(map, biome, rng):
		return null
	if not TerrainConnector.connect_everything(map, biome, rng):
		return null
	RoomDecorator.decorate(map, room, biome, rng)
	return map


static func _flat_center_radius(room: RoomData) -> float:
	match room.type:
		T.RoomType.BOSS:
			return mini(room.size.x, room.size.y) / 4.0
		T.RoomType.SHOP:
			return 5.0
		_:
			return 3.0
