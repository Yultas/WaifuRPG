class_name DungeonTypes
extends RefCounted
## Shared enums and helpers of the dungeon generator.

enum Dir { NORTH, EAST, SOUTH, WEST }
enum RoomType { START, COMBAT, SHOP, BOSS }
enum Terrain { LAND, WATER }
enum Structure { NONE, BRIDGE_H, BRIDGE_V, STAIRS }
enum BorderStyle { TREES, WATER, CLIFFS }

## Indexed by Dir.
const DIR_VECTORS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const AROUND_8: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0),
	Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


static func opposite(dir: int) -> int:
	return (dir + 2) % 4


static func is_horizontal(dir: int) -> bool:
	return dir == Dir.EAST or dir == Dir.WEST


static func room_type_name(type: int) -> String:
	return RoomType.keys()[type]


static func dir_name(dir: int) -> String:
	return Dir.keys()[dir]
