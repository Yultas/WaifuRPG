class_name BlobAutotile
extends RefCounted
## 8-neighbour ("blob") autotiling: the tile shape comes from which of the 8 neighbours
## belong to the same terrain. A corner neighbour only matters when both edges next to it
## match, which leaves 47 distinct shapes.

const N := 1
const NE := 2
const E := 4
const SE := 8
const S := 16
const SW := 32
const W := 64
const NW := 128

const _BITS: Array[int] = [NW, N, NE, W, E, SW, S, SE]
const _OFFSETS: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0),
	Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]

## Mask -> atlas coords for the 11x5 blob layout (Sprout Lands Grass.png and Hills.png).
## Read from the tile edges of Grass.png.
const LAYOUT_11X5: Dictionary[int, Vector2i] = {
	0: Vector2i(3, 3), 1: Vector2i(3, 2), 4: Vector2i(0, 3), 5: Vector2i(4, 3),
	7: Vector2i(0, 2), 16: Vector2i(3, 0), 17: Vector2i(3, 1), 20: Vector2i(4, 0),
	21: Vector2i(4, 4), 23: Vector2i(4, 1), 28: Vector2i(0, 0), 29: Vector2i(4, 2),
	31: Vector2i(0, 1), 64: Vector2i(2, 3), 65: Vector2i(7, 3), 68: Vector2i(1, 3),
	69: Vector2i(8, 3), 71: Vector2i(6, 3), 80: Vector2i(7, 0), 81: Vector2i(7, 4),
	84: Vector2i(8, 0), 85: Vector2i(8, 4), 87: Vector2i(9, 3), 92: Vector2i(6, 0),
	93: Vector2i(9, 2), 95: Vector2i(6, 4), 112: Vector2i(2, 0), 113: Vector2i(7, 2),
	116: Vector2i(5, 0), 117: Vector2i(10, 2), 119: Vector2i(9, 0), 124: Vector2i(1, 0),
	125: Vector2i(8, 2), 127: Vector2i(6, 2), 193: Vector2i(2, 2), 197: Vector2i(5, 3),
	199: Vector2i(1, 2), 209: Vector2i(7, 1), 213: Vector2i(10, 3), 215: Vector2i(8, 1),
	221: Vector2i(9, 1), 223: Vector2i(6, 1), 241: Vector2i(2, 1), 245: Vector2i(5, 4),
	247: Vector2i(5, 1), 253: Vector2i(5, 2), 255: Vector2i(1, 1),
}
const FULL := 255


static func canonical(mask: int) -> int:
	if not (mask & N and mask & E):
		mask &= ~NE
	if not (mask & S and mask & E):
		mask &= ~SE
	if not (mask & S and mask & W):
		mask &= ~SW
	if not (mask & N and mask & W):
		mask &= ~NW
	return mask


## Canonical mask of cell c in a solid grid (1 = same terrain). Cells outside the grid
## count as `outside`.
static func mask_at(solid: PackedByteArray, size: Vector2i, c: Vector2i, outside: bool) -> int:
	var mask := 0
	for k in 8:
		var n := c + _OFFSETS[k]
		var is_solid := outside
		if n.x >= 0 and n.y >= 0 and n.x < size.x and n.y < size.y:
			is_solid = solid[n.y * size.x + n.x] != 0
		if is_solid:
			mask |= _BITS[k]
	return canonical(mask)
