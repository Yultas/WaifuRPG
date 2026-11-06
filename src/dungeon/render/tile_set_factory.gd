class_name TileSetFactory
extends RefCounted
## Builds (and caches) a TileSet from a TileTheme at runtime, so themes stay plain
## texture + coordinate data that is easy to swap.

## Source ids. Prop atlas k of the theme gets source PROPS + k.
enum Source { WATER, LAND, HILLS, BRIDGE, ROAD, PROPS }

static var _cache: Dictionary[TileTheme, TileSet] = {}


static func get_tile_set(theme: TileTheme) -> TileSet:
	if _cache.has(theme):
		return _cache[theme]
	var size := theme.texture_tile_size
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(size, size)

	var water := _add_source(tile_set, Source.WATER, theme.water_texture, size)
	water.create_tile(Vector2i.ZERO)
	water.set_tile_animation_columns(Vector2i.ZERO, theme.water_frames)
	water.set_tile_animation_frames_count(Vector2i.ZERO, theme.water_frames)
	for frame in theme.water_frames:
		water.set_tile_animation_frame_duration(Vector2i.ZERO, frame, 1.0 / theme.water_fps)

	_create_tiles(_add_source(tile_set, Source.LAND, theme.land.texture, size), theme.land.all_tiles())
	var hills := _add_source(tile_set, Source.HILLS, theme.hills.texture, size)
	_create_tiles(hills, theme.hills.all_tiles())
	for o: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		_create_tiles(hills, [theme.stairs_origin + o])
	if theme.road != null:
		_create_tiles(_add_source(tile_set, Source.ROAD, theme.road.texture, size), theme.road.all_tiles())

	var bridge := _add_source(tile_set, Source.BRIDGE, theme.bridge_texture, size)
	_create_tiles(bridge, theme.bridge_vertical)
	_create_tiles(bridge, theme.bridge_horizontal)

	# Multi-cell props are anchored at their bottom-left cell: shift the texture so it
	# grows up and to the right from there.
	for k in theme.prop_atlases.size():
		var atlas := theme.prop_atlases[k]
		var props := _add_source(tile_set, Source.PROPS + k, atlas.texture, size)
		for rect: Rect2i in atlas.tiles.values():
			if props.has_tile(rect.position):
				continue
			props.create_tile(rect.position, rect.size)
			var half := size / 2
			props.get_tile_data(rect.position, 0).texture_origin = Vector2i(-(rect.size.x - 1) * half, (rect.size.y - 1) * half)

	_cache[theme] = tile_set
	return tile_set


## Source id and atlas rect of a prop in the theme, or source -1 if no atlas has it.
static func find_prop(theme: TileTheme, id: StringName) -> Array:
	for k in theme.prop_atlases.size():
		var atlas := theme.prop_atlases[k]
		if atlas.tiles.has(id):
			return [Source.PROPS + k, atlas.tiles[id]]
	return [-1, Rect2i()]


static func _add_source(tile_set: TileSet, id: int, texture: Texture2D, tile_size: int) -> TileSetAtlasSource:
	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(tile_size, tile_size)
	tile_set.add_source(source, id)
	return source


static func _create_tiles(source: TileSetAtlasSource, coords: Array) -> void:
	for c: Vector2i in coords:
		if not source.has_tile(c):
			source.create_tile(c)
