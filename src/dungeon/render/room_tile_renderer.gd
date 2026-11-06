class_name RoomTileRenderer
extends Node2D
## Draws a RoomMap with TileMapLayers, bottom to top: water, land, ground-level roads,
## bridges, then per elevation level its cliffs and roads, then `actors`: a y-sorted node
## with the prop tiles, where characters are added so they sort against trees and rocks.
## Tile choice depends only on the map and the cell position, so redraws are stable.
## The node is scaled so one cell is WorldUnits.CELL_PIXELS whatever the art's tile size;
## local_pixels_per_meter converts meters to this node's local space.

const T := preload("res://src/dungeon/dungeon_types.gd")
const Source := TileSetFactory.Source

## Y-sorted container of the props layer and characters. Survives re-renders.
var actors: Node2D
var props_layer: PropsLayer
var local_pixels_per_meter := WorldUnits.PIXELS_PER_METER

var _map: RoomMap
var _room_nodes: Array[Node] = []


func _init() -> void:
	actors = Node2D.new()
	actors.name = "Actors"
	actors.y_sort_enabled = true
	add_child(actors)


func render(map: RoomMap, biome: BiomeData) -> void:
	clear()
	_map = map
	var theme := biome.tile_theme
	var tile_set := TileSetFactory.get_tile_set(theme)
	local_pixels_per_meter = theme.texture_tile_size / WorldUnits.CELL_SIZE
	scale = Vector2.ONE * WorldUnits.CELL_PIXELS / theme.texture_tile_size

	# Bottom to top: water, land, roads on land, bridges, then per level its cliffs and
	# its roads, then the y-sorted actors.
	var water := _add_layer("Water", tile_set, biome.tint)
	var land := _add_layer("Land", tile_set, biome.tint)
	var roads: Array[TileMapLayer] = [_add_layer("Roads0", tile_set, biome.tint)]
	var bridges := _add_layer("Bridges", tile_set, biome.tint)
	var hills: Array[TileMapLayer] = []
	for l in range(1, _max_level() + 1):
		hills.append(_add_layer("Hills%d" % l, tile_set, biome.tint))
		roads.append(_add_layer("Roads%d" % l, tile_set, biome.tint))
	props_layer = PropsLayer.new()
	props_layer.name = "Props"
	props_layer.tile_set = tile_set
	props_layer.modulate = biome.tint
	props_layer.y_sort_enabled = true
	actors.add_child(props_layer)
	_room_nodes.append(props_layer)
	move_child(actors, -1)

	_draw_blob(land, Source.LAND, theme.land, func(i: int) -> bool: return map.terrain[i] == T.Terrain.LAND)
	for i in map.cell_count():
		var c := map.cell(i)
		water.set_cell(c, Source.WATER, Vector2i.ZERO)
		if map.is_bridge(c):
			bridges.set_cell(c, Source.BRIDGE, _bridge_tile(theme, c))
	for l in range(1, hills.size() + 1):
		_draw_blob(hills[l - 1], Source.HILLS, theme.hills, func(i: int) -> bool: return map.level[i] >= l)
	for top in map.stairs:
		var layer := hills[map.level_at(top) - 1]
		for o: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			layer.set_cell(top + o, Source.HILLS, theme.stairs_origin + o)
	if theme.road != null:
		for l in roads.size():
			_draw_blob(roads[l], Source.ROAD, theme.road, func(i: int) -> bool: return map.road[i] != 0 and map.level[i] == l)

	for placed in map.props:
		var found := TileSetFactory.find_prop(theme, placed.prop.id)
		if found[0] >= 0:
			props_layer.add_prop(placed.cell, found[0], found[1])
		else:
			push_warning("RoomTileRenderer: no tile for prop %s" % placed.prop.id)


## Adds a node (collision, triggers...) that belongs to the current room and is freed
## with it. It lives in this node's local space (see local_pixels_per_meter).
func add_room_node(node: Node) -> void:
	add_child(node)
	move_child(actors, -1)
	_room_nodes.append(node)


## Removes everything of the current room; characters in `actors` stay.
func clear() -> void:
	for node in _room_nodes:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.queue_free()
	_room_nodes.clear()
	props_layer = null
	_map = null


func _add_layer(layer_name: String, tile_set: TileSet, tint: Color) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = layer_name
	layer.tile_set = tile_set
	layer.modulate = tint
	add_room_node(layer)
	return layer


func _max_level() -> int:
	var top := 0
	for l in _map.level:
		top = maxi(top, l)
	return top


## Draws a blob sheet on every cell where `solid` (called with the cell index) is true.
## Cells outside the room count as solid, so room edges show no false borders.
func _draw_blob(layer: TileMapLayer, source: int, sheet: BlobSheet, solid: Callable) -> void:
	var mask_grid := PackedByteArray()
	mask_grid.resize(_map.cell_count())
	for i in _map.cell_count():
		mask_grid[i] = 1 if solid.call(i) else 0
	for i in _map.cell_count():
		if mask_grid[i] == 0:
			continue
		var c := _map.cell(i)
		var mask := BlobAutotile.mask_at(mask_grid, _map.size, c, true)
		layer.set_cell(c, source, _blob_tile(sheet, mask, c, _map.lush[i] != 0))


func _blob_tile(sheet: BlobSheet, mask: int, c: Vector2i, lush: bool) -> Vector2i:
	if mask != BlobAutotile.FULL:
		return sheet.tile(mask)
	if lush and not sheet.lush_variants.is_empty():
		return _pick(sheet.lush_variants, c, 1)
	if not sheet.plain_variants.is_empty() and _roll(c, 2) < sheet.plain_variant_chance:
		return _pick(sheet.plain_variants, c, 9)
	return sheet.tile(BlobAutotile.FULL)


func _bridge_tile(theme: TileTheme, c: Vector2i) -> Vector2i:
	var s := _map.structure[_map.idx(c)]
	var vertical := s == T.Structure.BRIDGE_V
	var tiles := theme.bridge_vertical if vertical else theme.bridge_horizontal
	var back := c + (Vector2i.UP if vertical else Vector2i.LEFT)
	var front := c + (Vector2i.DOWN if vertical else Vector2i.RIGHT)
	# Outside the room the bridge continues (door bridges over a water border).
	var has_back := not _map.in_bounds(back) or _map.structure[_map.idx(back)] == s
	var has_front := not _map.in_bounds(front) or _map.structure[_map.idx(front)] == s
	if has_back == has_front:
		return tiles[1]
	return tiles[2] if has_back else tiles[0]


## Stable pseudo-random value in [0, 1) for a cell.
func _roll(c: Vector2i, salt: int) -> float:
	return float(hash(Vector3i(c.x, c.y, salt)) & 0xFFFF) / 65536.0


func _pick(options: Array[Vector2i], c: Vector2i, salt: int) -> Vector2i:
	return options[int(_roll(c, salt) * options.size()) % options.size()]
