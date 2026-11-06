class_name DungeonGenerator
extends RefCounted
## Entry point: builds the room graph, then every room's map. The same seed and config
## always give the same dungeon. Each room gets its own sub-seed, so tweaking one room
## type does not reshuffle the others.


static func generate(config: DungeonConfig, run_seed: int, biome: BiomeData = null) -> DungeonData:
	if biome == null:
		biome = config.biome
	assert(biome != null, "DungeonGenerator: no biome")
	var rng := RandomNumberGenerator.new()
	rng.seed = run_seed
	var dungeon := LayoutGenerator.generate(config, rng)
	if dungeon == null:
		return null
	dungeon.run_seed = run_seed
	dungeon.biome = biome
	for room in dungeon.rooms:
		room.room_seed = hash([run_seed, room.index])
		room.map = RoomGenerator.generate(room, config, biome)
	return dungeon
