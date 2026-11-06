class_name DungeonData
extends RefCounted
## Result of the dungeon generator: the room graph plus every room's map.

var run_seed := 0
var biome: BiomeData
var rooms: Array[RoomData] = []
var start_index := 0
var boss_index := -1
## -1 when the dungeon has no shop.
var shop_index := -1


func room_at(grid_pos: Vector2i) -> RoomData:
	for room in rooms:
		if room.grid_pos == grid_pos:
			return room
	return null


## Room behind the given door of a room, or null.
func neighbor(room: RoomData, dir: int) -> RoomData:
	if not room.neighbors.has(dir):
		return null
	return rooms[room.neighbors[dir]]
