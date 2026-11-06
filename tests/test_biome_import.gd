extends SceneTree
## Checks of the biome importer: the blob scanner must find the same tiles as the
## hand-made themes, the pine fixture must rebuild the pine forest props, and the imported
## biome must generate valid dungeons and survive a save/load round trip.
## Run: godot --headless --path . -s res://tests/test_biome_import.gd

const FIXTURE := "res://tests/fixtures/pine_import"
const OUT := "user://import_test"

var _failures := 0


func _init() -> void:
	_check_scanner_on_themes()
	var result := BiomeImporter.run(FIXTURE, OUT)
	for error in result.errors:
		_fail("import: " + error)
	if result.errors.is_empty():
		_check_against_pine(result)
		_check_generation(result.biome)
		_check_round_trip(result)
	if _failures == 0:
		print("ALL PASSED")
	else:
		print("FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


## Every blob sheet of every theme, scanned from its layout's first row down, must give
## the tile the theme draws for each of the 47 shapes.
func _check_scanner_on_themes() -> void:
	for file in ResourceLoader.list_directory("res://data/themes"):
		if not file.ends_with(".tres"):
			continue
		var theme: TileTheme = load("res://data/themes".path_join(file))
		var sheets := {"land": theme.land, "road": theme.road, "hills": theme.hills}
		for name: String in sheets:
			var sheet: BlobSheet = sheets[name]
			if sheet == null:
				continue
			var image := sheet.texture.get_image()
			var grid := Vector2i(image.get_width(), image.get_height()) / theme.texture_tile_size
			var region := Rect2i(0, sheet.layout_origin.y, grid.x, grid.y - sheet.layout_origin.y)
			var exclude: Array[Rect2i] = []
			if name == "hills":
				exclude.append(Rect2i(theme.stairs_origin, Vector2i(2, 2)))
			var scan := BlobScanner.scan(image, theme.texture_tile_size, region, exclude)
			var wrong := 0
			for mask in BlobAutotile.LAYOUT_11X5:
				if scan.layout.get(mask, Vector2i(-1, -1)) != sheet.tile(mask):
					wrong += 1
			if wrong > 0:
				_fail("%s %s: %d of 47 shapes differ from the theme" % [file, name, wrong])
			else:
				print("%-12s %-6s 47/47 shapes match" % [file, name])


func _check_against_pine(result: BiomeImporter.Result) -> void:
	var pine: TileTheme = load("res://data/themes/pine.tres")
	var pairs := {"land": [result.theme.land, pine.land], "road": [result.theme.road, pine.road],
		"hills": [result.theme.hills, pine.hills]}
	for name: String in pairs:
		var got: BlobSheet = pairs[name][0]
		var want: BlobSheet = pairs[name][1]
		for mask in BlobAutotile.LAYOUT_11X5:
			if got.tile(mask) != want.tile(mask):
				_fail("%s mask %d: %s, hand-made %s" % [name, mask, got.tile(mask), want.tile(mask)])
		print("%-6s variants: %d plain, %d lush (hand-made %d, %d)" % [name, got.plain_variants.size(),
			got.lush_variants.size(), want.plain_variants.size(), want.lush_variants.size()])
	var imported := {}
	for prop in result.props:
		imported[prop.id] = prop
	var compared := 0
	for atlas in pine.prop_atlases:
		for id: StringName in atlas.tiles:
			if not imported.has(id):
				continue
			compared += 1
			var rect: Rect2i = TileSetFactory.find_prop(result.theme, id)[1]
			if rect != atlas.tiles[id]:
				_fail("prop %s: rect %s, hand-made %s" % [id, rect, atlas.tiles[id]])
			var mine: PropDef = imported[id]
			var hand: PropDef = load("res://data/props/%s.tres" % id)
			if mine.size != hand.size or mine.blocking != hand.blocking or mine.placement != hand.placement:
				_fail("prop %s: size/blocking/placement differ from the hand-made one" % id)
			elif hand.blocking and (absf(mine.collision_size.x - hand.collision_size.x) > 0.2):
				_fail("prop %s: collision %s, hand-made %s" % [id, mine.collision_size, hand.collision_size])
	if compared < 18:
		_fail("only %d props matched hand-made ones by name" % compared)
	print("props: %d imported, %d compared with hand-made" % [result.props.size(), compared])
	if TileSetFactory.get_tile_set(result.theme) == null:
		_fail("no tile set for the imported theme")


func _check_generation(biome: BiomeData) -> void:
	var config: DungeonConfig = load("res://data/dungeon/default_dungeon.tres")
	for s in 10:
		var dungeon := DungeonGenerator.generate(config, s, biome)
		if dungeon == null:
			_fail("seed %d: no dungeon" % s)
			continue
		for room in dungeon.rooms:
			if room.map == null:
				_fail("seed %d room %d failed" % [s, room.index])
	print("generation: 10 dungeons with the imported biome")


func _check_round_trip(result: BiomeImporter.Result) -> void:
	var err := BiomeImporter.save(result, OUT)
	if err != OK:
		_fail("save: %s" % error_string(err))
		return
	var biome: BiomeData = ResourceLoader.load(OUT.path_join("biomes/pine_import.tres"), "", ResourceLoader.CACHE_MODE_IGNORE)
	if biome == null or biome.tile_theme == null or biome.tile_theme.prop_atlases.size() != result.atlases.size():
		_fail("round trip: saved biome does not load back")
	elif biome.props.size() != result.biome.props.size() or biome.border_props.size() != result.biome.border_props.size():
		_fail("round trip: props lost")
	else:
		print("round trip: saved and loaded back from %s" % OUT)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FAIL: " + message)
