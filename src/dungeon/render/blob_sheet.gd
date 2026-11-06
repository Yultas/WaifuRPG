class_name BlobSheet
extends Resource
## A texture with the 47 blob shapes in the 11x5 layout (see BlobAutotile.LAYOUT_11X5),
## plus optional variants of the full (interior) tile.

@export var texture: Texture2D
## Atlas position of the layout's top-left tile (the layout may start lower in the sheet).
@export var layout_origin := Vector2i.ZERO
## Mask -> absolute atlas coords where this sheet differs from the standard layout.
@export var layout_overrides: Dictionary[int, Vector2i] = {}
## Full tiles that replace the plain interior now and then.
@export var plain_variants: Array[Vector2i] = []
@export_range(0.0, 1.0, 0.01) var plain_variant_chance := 0.15
## Full tiles for lush cells (RoomMap.lush). Empty = lush cells look plain.
@export var lush_variants: Array[Vector2i] = []


func tile(mask: int) -> Vector2i:
	if layout_overrides.has(mask):
		return layout_overrides[mask]
	return BlobAutotile.LAYOUT_11X5[mask] + layout_origin


## Every atlas tile this sheet can draw.
func all_tiles() -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for mask in BlobAutotile.LAYOUT_11X5:
		tiles.append(tile(mask))
	tiles.append_array(plain_variants)
	tiles.append_array(lush_variants)
	return tiles
