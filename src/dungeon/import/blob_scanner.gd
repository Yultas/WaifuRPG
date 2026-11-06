class_name BlobScanner
extends RefCounted
## Reads blob tile shapes (see BlobAutotile) straight from the pixels of a sheet, so a
## sheet may lay its 47 tiles out in any order.
##
## A side of a tile counts as connected when the pixels along that side are "surface":
## opaque and close to the sheet's fill color (its most common opaque color). Transparent
## margins, shore rims and cliff faces all read as open sides. Sides are sampled in the
## upper part of the tile where faces could hide them (W, E), corners by their outer pixel.
##
## Full tiles beyond the first one become variants: plain when they barely differ from the
## fill color, lush otherwise. Tiles whose pattern runs over their edges are parts of
## multi-tile pictures and are left out (they would show seams when placed alone).

## RGB distance (0..441) under which a pixel matches the fill color.
const SURFACE_DISTANCE := 40.0
## A side is connected when at least this share of its samples is surface.
const SIDE_SHARE := 0.5
## Tiles with fewer opaque pixels than this share are empty.
const MIN_OPAQUE := 0.05
## RGB distance at which a pixel of a full tile counts as decoration.
const DETAIL_DISTANCE := 12.0
## A full tile with more decorated pixels than this share is lush.
const LUSH_SHARE := 0.06
## A full tile with more decorated pixels on its border than this share is a fragment.
const SEAM_SHARE := 0.15


class Result:
	## Canonical mask -> atlas coords of the first tile with that shape.
	var layout: Dictionary[int, Vector2i] = {}
	## Masks of the standard 47 that the sheet lacks.
	var missing: Array[int] = []
	var plain: Array[Vector2i] = []
	var lush: Array[Vector2i] = []
	var fill := Color()


## Scans the tiles of `region` (in tiles; empty = whole sheet) row by row. Tiles inside
## `exclude` rects (stairs and the like) are skipped.
static func scan(image: Image, tile_size: int, region := Rect2i(), exclude: Array[Rect2i] = []) -> Result:
	var result := Result.new()
	var grid := Vector2i(image.get_width(), image.get_height()) / tile_size
	if region.size == Vector2i.ZERO:
		region = Rect2i(Vector2i.ZERO, grid)
	region = region.intersection(Rect2i(Vector2i.ZERO, grid))
	result.fill = _fill_color(image, tile_size, region)
	var full: Array[Vector2i] = []
	for ty in range(region.position.y, region.end.y):
		for tx in range(region.position.x, region.end.x):
			var t := Vector2i(tx, ty)
			if _excluded(t, exclude) or _opaque_share(image, tile_size, t) < MIN_OPAQUE:
				continue
			var mask := _mask(image, tile_size, t, result.fill)
			if not result.layout.has(mask):
				result.layout[mask] = t
			elif mask == BlobAutotile.FULL:
				full.append(t)
	for mask in BlobAutotile.LAYOUT_11X5:
		if not result.layout.has(mask):
			result.missing.append(mask)
	for t in full:
		if _opaque_share(image, tile_size, t) < 1.0 or _border_detail(image, tile_size, t, result.fill) > SEAM_SHARE:
			continue
		if _detail(image, tile_size, t, result.fill) > LUSH_SHARE:
			result.lush.append(t)
		else:
			result.plain.append(t)
	return result


## Layout origin and overrides that reproduce `layout` on top of the standard 11x5
## layout: the origin is the most common shift, the rest are overrides.
static func to_origin_and_overrides(layout: Dictionary[int, Vector2i]) -> Array:
	var votes: Dictionary[Vector2i, int] = {}
	for mask in layout:
		if BlobAutotile.LAYOUT_11X5.has(mask):
			var shift := layout[mask] - BlobAutotile.LAYOUT_11X5[mask]
			votes[shift] = votes.get(shift, 0) + 1
	var origin := Vector2i.ZERO
	for shift in votes:
		if votes[shift] > votes.get(origin, 0):
			origin = shift
	var overrides: Dictionary[int, Vector2i] = {}
	for mask in layout:
		if BlobAutotile.LAYOUT_11X5.has(mask) and layout[mask] != BlobAutotile.LAYOUT_11X5[mask] + origin:
			overrides[mask] = layout[mask]
	return [origin, overrides]


static func _mask(image: Image, size: int, t: Vector2i, fill: Color) -> int:
	var o := t * size
	var last := size - 1
	var mask := 0
	var sides := {
		BlobAutotile.N: _row(o, range(size / 4, size - size / 4), 0),
		BlobAutotile.S: _row(o, range(size / 4, size - size / 4), last),
		BlobAutotile.W: _column(o, 0, range(size / 8, 3 * size / 8 + 1)),
		BlobAutotile.E: _column(o, last, range(size / 8, 3 * size / 8 + 1)),
		BlobAutotile.NW: [o],
		BlobAutotile.NE: [o + Vector2i(last, 0)],
		BlobAutotile.SW: [o + Vector2i(0, last)],
		BlobAutotile.SE: [o + Vector2i(last, last)],
	}
	for bit: int in sides:
		var points: Array = sides[bit]
		var hits := 0
		for p: Vector2i in points:
			hits += int(_is_surface(image.get_pixelv(p), fill))
		if hits >= points.size() * SIDE_SHARE:
			mask |= bit
	return BlobAutotile.canonical(mask)


static func _row(o: Vector2i, xs: Array, y: int) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	for x: int in xs:
		points.append(o + Vector2i(x, y))
	return points


static func _column(o: Vector2i, x: int, ys: Array) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	for y: int in ys:
		points.append(o + Vector2i(x, y))
	return points


static func _is_surface(c: Color, fill: Color) -> bool:
	return c.a >= 0.5 and _distance(c, fill) < SURFACE_DISTANCE


## RGB distance in 0..255 units.
static func _distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() * 255.0


static func _fill_color(image: Image, size: int, region: Rect2i) -> Color:
	var counts: Dictionary[int, int] = {}
	var best := 0
	var best_count := 0
	var from := region.position * size
	var to := region.end * size
	for y in range(from.y, to.y):
		for x in range(from.x, to.x):
			var c := image.get_pixel(x, y)
			if c.a < 0.5:
				continue
			var key := c.to_rgba32() | 0xff
			var n: int = counts.get(key, 0) + 1
			counts[key] = n
			if n > best_count:
				best = key
				best_count = n
	return Color.hex(best)


static func _opaque_share(image: Image, size: int, t: Vector2i) -> float:
	var opaque := 0
	for y in size:
		for x in size:
			opaque += int(image.get_pixel(t.x * size + x, t.y * size + y).a >= 0.5)
	return float(opaque) / (size * size)


static func _detail(image: Image, size: int, t: Vector2i, fill: Color) -> float:
	var detailed := 0
	for y in size:
		for x in size:
			detailed += int(_distance(image.get_pixel(t.x * size + x, t.y * size + y), fill) >= DETAIL_DISTANCE)
	return float(detailed) / (size * size)


static func _border_detail(image: Image, size: int, t: Vector2i, fill: Color) -> float:
	var detailed := 0
	var total := 0
	for y in size:
		for x in size:
			if x != 0 and y != 0 and x != size - 1 and y != size - 1:
				continue
			total += 1
			detailed += int(_distance(image.get_pixel(t.x * size + x, t.y * size + y), fill) >= DETAIL_DISTANCE)
	return float(detailed) / total


static func _excluded(t: Vector2i, exclude: Array[Rect2i]) -> bool:
	for rect in exclude:
		if rect.has_point(t):
			return true
	return false
