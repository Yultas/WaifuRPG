class_name TileTheme
extends Resource
## Which atlas tiles draw each kind of room cell. Ground, roads and cliffs are blob
## sheets (see BlobSheet), props come from one or more atlases.

## Pixel size of one tile in the source textures. A property of the art, not a world
## unit: the renderer scales tiles so one cell is WorldUnits.CELL_PIXELS on screen.
@export var texture_tile_size := 16

@export_group("Water")
## Animation frames laid out in one row starting at (0, 0).
@export var water_texture: Texture2D
@export var water_frames := 4
@export var water_fps := 3.0

@export_group("Ground")
## Dry land drawn over water; its edges are shores.
@export var land: BlobSheet
## Road overlay drawn on top of the ground of its level. Null = no roads drawn.
@export var road: BlobSheet

@export_group("Hills")
## High ground, one layer per level; edge tiles include the cliff face.
@export var hills: BlobSheet
## Top-left tile of the 2x2 stairs block in the hills texture.
@export var stairs_origin := Vector2i(9, 5)
## Depth (in cells) of the cliff face drawn in the lower part of high-ground edge tiles.
## Characters on the upper level stop at the top of the face (see RoomCollision).
@export_range(0.0, 1.0, 0.5) var cliff_face_depth := 0.5

@export_group("Bridges")
@export var bridge_texture: Texture2D
## Start (north), middle, end (south).
@export var bridge_vertical: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)]
## Start (west), middle, end (east).
@export var bridge_horizontal: Array[Vector2i] = [Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0)]

@export_group("Props")
## Atlases searched in order for a PropDef.id.
@export var prop_atlases: Array[PropAtlas] = []
