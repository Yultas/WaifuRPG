class_name RoomData
extends RefCounted
## One room of the dungeon graph.

var index := 0
## Position on the dungeon grid (one grid cell per room).
var grid_pos := Vector2i.ZERO
var type: DungeonTypes.RoomType = DungeonTypes.RoomType.COMBAT
## Room size in grid cells (1 cell = 1 m, see WorldUnits).
var size := Vector2i.ZERO
## Number of doors between this room and the start room.
var depth := 0
## Dir -> index of the room behind that door.
var neighbors: Dictionary[int, int] = {}
var room_seed := 0
var map: RoomMap
## Attempts the room generator needed (1 = first try).
var attempts := 0
