class_name PropsLayer
extends TileMapLayer
## Y-sorted prop tiles. A prop that hides a character standing behind it (character
## inside the sprite and north of its base) is drawn semi-transparent.

const FADE_ALPHA := 0.45


class Sprite:
	var anchor: Vector2i
	## Sprite bounds in local pixels.
	var rect: Rect2


var _sprites: Array[Sprite] = []
var _faded: Dictionary[Vector2i, bool] = {}
## Every tile that was ever faded. The layer keeps its runtime-updated data cached, so
## these tiles stay runtime-updated and get their alpha set back explicitly.
var _touched: Dictionary[Vector2i, bool] = {}


func add_prop(anchor: Vector2i, source: int, atlas: Rect2i) -> void:
	set_cell(anchor, source, atlas.position)
	var tile := Vector2(tile_set.tile_size)
	var sprite := Sprite.new()
	sprite.anchor = anchor
	sprite.rect = Rect2(Vector2(anchor.x, anchor.y - atlas.size.y + 1) * tile, Vector2(atlas.size) * tile)
	_sprites.append(sprite)


## Fades props that cover any of the given characters. Each character is given by its feet
## position and its height, both in local pixels.
func update_fade(feet: PackedVector2Array, height: float) -> void:
	var faded: Dictionary[Vector2i, bool] = {}
	for sprite in _sprites:
		var base_y := sprite.rect.end.y
		for p in feet:
			if p.y < base_y and sprite.rect.intersects(Rect2(p - Vector2(2.0, height), Vector2(4.0, height))):
				faded[sprite.anchor] = true
				break
	if faded == _faded:
		return
	_faded = faded
	_touched.merge(faded)
	notify_runtime_tile_data_update()


func _use_tile_data_runtime_update(coords: Vector2i) -> bool:
	return _touched.has(coords)


func _tile_data_runtime_update(coords: Vector2i, tile_data: TileData) -> void:
	tile_data.modulate.a = FADE_ALPHA if _faded.has(coords) else 1.0
