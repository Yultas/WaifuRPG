class_name WorldUnits
extends RefCounted
## The project's single length unit: 1 meter = 1 room grid cell.
## Gameplay values (positions, speeds, radii, ranges) are in meters and seconds.
## Pixels exist only in presentation and always come from PIXELS_PER_METER.
##
## The game is pure 2D. Axes: grid x -> world x (east), grid y -> world y (south).
## Elevation is not a world axis: it is the terrain level index of a cell.
## A room's origin is the top-left corner of its cell (0, 0).

## Meters per grid cell.
const CELL_SIZE := 1.0
## Screen pixels per meter.
const PIXELS_PER_METER := 16.0
## Screen pixels per grid cell.
const CELL_PIXELS := CELL_SIZE * PIXELS_PER_METER


## World position (meters) of the center of a cell.
static func cell_to_world(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * CELL_SIZE


## Cell under a world position (meters).
static func world_to_cell(position: Vector2) -> Vector2i:
	return Vector2i(floori(position.x / CELL_SIZE), floori(position.y / CELL_SIZE))


## Top-left corner of a cell in 2D pixels.
static func cell_to_pixels(cell: Vector2i) -> Vector2:
	return Vector2(cell) * CELL_PIXELS


static func meters_to_pixels(meters: float) -> float:
	return meters * PIXELS_PER_METER


static func pixels_to_meters(pixels: float) -> float:
	return pixels / PIXELS_PER_METER
