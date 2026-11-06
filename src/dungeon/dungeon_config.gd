class_name DungeonConfig
extends Resource
## Dungeon-level generation settings: room count, special rooms and room sizes.

@export var biome: BiomeData

@export_group("Rooms")
## Counts include the start, boss and shop rooms.
@export_range(3, 30) var min_rooms := 7
@export_range(3, 30) var max_rooms := 11
@export_range(0.0, 1.0, 0.01) var shop_chance := 0.35
## Chance to link two adjacent regular rooms that the room tree did not connect.
@export_range(0.0, 1.0, 0.01) var extra_connection_chance := 0.1

# Sizes are in grid cells (1 cell = 1 m, see WorldUnits).
@export_group("Room sizes")
@export var start_room_size := Vector2i(24, 18)
@export var combat_room_min := Vector2i(28, 20)
@export var combat_room_max := Vector2i(40, 30)
@export var shop_room_size := Vector2i(22, 18)
@export var boss_room_size := Vector2i(40, 32)

@export_group("Generation")
@export_range(2, 5) var door_width := 3
## Attempts per room. The last attempt is flat terrain and always succeeds.
@export_range(1, 16) var max_room_attempts := 6
