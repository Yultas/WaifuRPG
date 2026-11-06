class_name PropSlicer
extends RefCounted
## Finds the sprites on a prop sheet and measures what PropDef needs from them.
## A sprite is a group of touching opaque pixels; groups whose tile rects overlap are one
## sprite (a flower with loose petals, a tree with a separate shadow). Sprites are expected
## to sit on the tile grid, as they do in tile packs.

## Coverage of the bottom tile row above which a 1x1 sprite blocks movement by default.
const SOLID_COVERAGE := 0.4
## Pixel rows above the lowest opaque one that make up the trunk or base.
const BASE_ROWS := 4


class Sprite:
	## In tiles.
	var rect: Rect2i
	## Share of opaque pixels in the bottom tile row.
	var coverage := 0.0
	## Width of the base (lowest opaque rows), in tiles (= meters).
	var base_width := 0.0
	## Transparent gap under the base, in tiles.
	var gap := 0.0


## Sprites sorted top to bottom, then left to right.
static func slice(image: Image, tile_size: int) -> Array[Sprite]:
	var rects := _merge(_components(image, tile_size))
	rects.sort_custom(func(a: Rect2i, b: Rect2i) -> bool:
		return a.position.y < b.position.y or (a.position.y == b.position.y and a.position.x < b.position.x))
	var sprites: Array[Sprite] = []
	for rect in rects:
		sprites.append(_measure(image, tile_size, rect))
	return sprites


## Tile rect of every 8-connected group of opaque pixels.
static func _components(image: Image, size: int) -> Array[Rect2i]:
	var w := image.get_width()
	var h := image.get_height()
	var seen := PackedByteArray()
	seen.resize(w * h)
	var rects: Array[Rect2i] = []
	var stack := PackedInt32Array()
	for start in w * h:
		if seen[start] != 0 or image.get_pixel(start % w, start / w).a < 0.5:
			continue
		seen[start] = 1
		stack.append(start)
		var lo := Vector2i(start % w, start / w)
		var hi := lo
		while not stack.is_empty():
			var i := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			var p := Vector2i(i % w, i / w)
			lo = lo.min(p)
			hi = hi.max(p)
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var n := p + Vector2i(dx, dy)
					if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h:
						continue
					var ni := n.y * w + n.x
					if seen[ni] == 0 and image.get_pixelv(n).a >= 0.5:
						seen[ni] = 1
						stack.append(ni)
		rects.append(Rect2i(lo / size, hi / size - lo / size + Vector2i.ONE))
	return rects


static func _merge(rects: Array[Rect2i]) -> Array[Rect2i]:
	var merged := true
	while merged:
		merged = false
		for i in rects.size():
			for j in range(i + 1, rects.size()):
				if rects[i].intersects(rects[j]):
					rects[i] = rects[i].merge(rects[j])
					rects.remove_at(j)
					merged = true
					break
			if merged:
				break
	return rects


static func _measure(image: Image, size: int, rect: Rect2i) -> Sprite:
	var sprite := Sprite.new()
	sprite.rect = rect
	var left := rect.position.x * size
	var width := rect.size.x * size
	var top := (rect.end.y - 1) * size
	var opaque := 0
	var lowest := -1
	for y in size:
		for x in width:
			if image.get_pixel(left + x, top + y).a >= 0.5:
				opaque += 1
				lowest = y
	sprite.coverage = float(opaque) / (width * size)
	if lowest < 0:
		return sprite
	var min_x := width
	var max_x := -1
	for y in range(maxi(lowest - BASE_ROWS + 1, 0), lowest + 1):
		for x in width:
			if image.get_pixel(left + x, top + y).a >= 0.5:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
	sprite.base_width = float(max_x - min_x + 1) / size
	sprite.gap = float(size - 1 - lowest) / size
	return sprite
