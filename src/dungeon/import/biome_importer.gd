class_name BiomeImporter
extends RefCounted
## Builds a biome from a folder of tile sheets: reads every sheet, finds the blob tiles and
## the props on its own and produces TileTheme, PropAtlas, PropDef and BiomeData resources.
## A biome.cfg manifest in the folder points at the sheets and fills in what pixels cannot
## tell (names, which props block, the stairs position). See docs/biome_import.md.
##
## The art plus the manifest are the source: the theme, atlases and props are rebuilt on
## every import. Only the generation parameters of an existing biome file are kept (they
## are tuned in the editor), the template biome gives them on the first import.

const MANIFEST := "biome.cfg"

## Default scatter rules by kind of prop: [density, clustering].
const TREE_RULE := [0.02, 0.8]
const HUGE_TREE_RULE := [0.006, 0.9]
const SOLID_RULE := [0.008, 0.4]
const PLANT_RULE := [0.02, 0.4]
const WATER_RULE := [0.03, 0.0]


class Result:
	var biome: BiomeData
	var theme: TileTheme
	var atlases: Array[PropAtlas] = []
	## Sheet name of each atlas (the props.<name> section).
	var atlas_names: PackedStringArray = []
	var props: Array[PropDef] = []
	var report := PackedStringArray()
	## Problems that make the result unusable. Empty = ok.
	var errors := PackedStringArray()


## Imports the biome in `folder` (res:// path). `out` is where save() will write (an
## existing biome there keeps its generation parameters). Nothing is saved yet.
static func run(folder: String, out := "res://data") -> Result:
	var result := Result.new()
	var cfg := _manifest(folder)
	var id := StringName(cfg.get_value("biome", "id", folder.trim_suffix("/").get_file()))
	var size: int = cfg.get_value("biome", "tile_size", 16)
	var theme := TileTheme.new()
	theme.texture_tile_size = size
	result.theme = theme

	theme.land = _blob_sheet(folder, cfg, "land", size, [], result)
	theme.road = _blob_sheet(folder, cfg, "road", size, [], result) if cfg.has_section("road") else null
	theme.stairs_origin = cfg.get_value("hills", "stairs", theme.stairs_origin)
	theme.cliff_face_depth = cfg.get_value("hills", "face_depth", theme.cliff_face_depth)
	theme.hills = _blob_sheet(folder, cfg, "hills", size, [Rect2i(theme.stairs_origin, Vector2i(2, 2))], result)

	theme.water_texture = _texture(folder, cfg, "water", result)
	if theme.water_texture != null:
		theme.water_frames = cfg.get_value("water", "frames", maxi(theme.water_texture.get_width() / size, 1))
		theme.water_fps = cfg.get_value("water", "fps", theme.water_fps)
	theme.bridge_texture = _texture(folder, cfg, "bridge", result)
	theme.bridge_vertical.assign(cfg.get_value("bridge", "vertical", theme.bridge_vertical))
	theme.bridge_horizontal.assign(cfg.get_value("bridge", "horizontal", theme.bridge_horizontal))

	var border: Array[PropDef] = []
	var rules: Array[PropRule] = []
	for section in cfg.get_sections():
		if section.begins_with("props."):
			_import_props(folder, cfg, section, size, result, rules, border)
	if border.is_empty():
		border = _default_border(result.props)
	theme.prop_atlases = result.atlases

	result.biome = _biome(cfg, id, out)
	result.biome.tile_theme = theme
	result.biome.props = rules
	result.biome.border_props = border
	if result.biome.border_style == DungeonTypes.BorderStyle.TREES and border.is_empty():
		result.errors.append("border style is TREES but there are no trees for the border")
	result.report.append("border: %s" % ", ".join(border.map(func(p: PropDef) -> String: return p.id)))
	return result


## Writes the result under `out` (default res://data): biomes/<id>.tres, themes/<id>.tres,
## themes/atlases/<id>_<sheet>.tres and props/<id>/*.tres. Prop files left over from an
## earlier import of the same biome are deleted.
static func save(result: Result, out := "res://data") -> Error:
	var id := String(result.biome.id)
	var props_dir := out.path_join("props").path_join(id)
	for dir in [out.path_join("biomes"), out.path_join("themes/atlases"), props_dir]:
		DirAccess.make_dir_recursive_absolute(dir)
	var kept := {}
	for prop in result.props:
		var file := "%s.tres" % prop.id
		kept[file] = true
		var err := _save(prop, props_dir.path_join(file))
		if err != OK:
			return err
	for file in DirAccess.get_files_at(props_dir):
		if file.ends_with(".tres") and not kept.has(file):
			DirAccess.remove_absolute(props_dir.path_join(file))
	for k in result.atlases.size():
		var err := _save(result.atlases[k], out.path_join("themes/atlases/%s_%s.tres" % [id, result.atlas_names[k]]))
		if err != OK:
			return err
	var err := _save(result.theme, out.path_join("themes/%s.tres" % id))
	if err != OK:
		return err
	return _save(result.biome, out.path_join("biomes/%s.tres" % id))


static func _save(resource: Resource, path: String) -> Error:
	resource.take_over_path(path)
	return ResourceSaver.save(resource, path)


## The folder's biome.cfg, or one guessed from file names: land.png, road.png, hills.png,
## water.png, bridge.png, props*.png (land props), water_props*.png (water props).
static func _manifest(folder: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	var path := folder.path_join(MANIFEST)
	if FileAccess.file_exists(path):
		cfg.load(path)
		return cfg
	for file in DirAccess.get_files_at(folder):
		var stem := file.get_basename()
		if file.get_extension() != "png":
			continue
		if stem in ["land", "road", "hills", "water", "bridge"]:
			cfg.set_value(stem, "texture", file)
		elif stem.begins_with("water_props"):
			cfg.set_value("props." + stem, "texture", file)
			cfg.set_value("props." + stem, "placement", "water")
		elif stem.begins_with("props"):
			cfg.set_value("props." + stem, "texture", file)
	return cfg


static func _texture(folder: String, cfg: ConfigFile, section: String, result: Result) -> Texture2D:
	var file: String = cfg.get_value(section, "texture", section + ".png")
	var path := file if file.begins_with("res://") else folder.path_join(file)
	var texture: Texture2D = load(path) if ResourceLoader.exists(path) else null
	if texture == null:
		result.errors.append("[%s] texture %s not found (new images need an import first)" % [section, path])
	return texture


static func _blob_sheet(folder: String, cfg: ConfigFile, section: String, size: int, exclude: Array[Rect2i],
		result: Result) -> BlobSheet:
	var texture := _texture(folder, cfg, section, result)
	if texture == null:
		return null
	var region: Rect2i = cfg.get_value(section, "region", Rect2i())
	var scan := BlobScanner.scan(texture.get_image(), size, region, exclude)
	if not scan.missing.is_empty():
		result.errors.append("[%s] no tiles for masks %s" % [section, scan.missing])
	var sheet := BlobSheet.new()
	sheet.texture = texture
	var placement := BlobScanner.to_origin_and_overrides(scan.layout)
	sheet.layout_origin = placement[0]
	sheet.layout_overrides = placement[1]
	sheet.plain_variants = scan.plain
	# lush = false: the sheet has no lush look, every variant is plain.
	if cfg.get_value(section, "lush", true):
		sheet.lush_variants = scan.lush
	else:
		sheet.plain_variants.append_array(scan.lush)
	sheet.plain_variant_chance = cfg.get_value(section, "plain_variant_chance", sheet.plain_variant_chance)
	result.report.append("[%s] %d/47 shapes, origin %s, %d overrides, %d plain, %d lush variants" % [
		section, 47 - scan.missing.size(), sheet.layout_origin, sheet.layout_overrides.size(),
		sheet.plain_variants.size(), sheet.lush_variants.size()])
	return sheet


static func _import_props(folder: String, cfg: ConfigFile, section: String, size: int, result: Result,
		rules: Array[PropRule], border: Array[PropDef]) -> void:
	var sheet := section.trim_prefix("props.")
	var texture := _texture(folder, cfg, section, result)
	if texture == null:
		return
	var on_water: bool = cfg.get_value(section, "placement", "land") == "water"
	var names: Dictionary = cfg.get_value(section, "names", {})
	var skip: Array = cfg.get_value(section, "skip", [])
	var walkable: Array = cfg.get_value(section, "walkable", [])
	var blocking: Array = cfg.get_value(section, "blocking", [])
	var border_ids: Array = cfg.get_value(section, "border", [])
	var densities: Dictionary = cfg.get_value(section, "density", {})
	var clusterings: Dictionary = cfg.get_value(section, "clustering", {})
	var collisions: Dictionary = cfg.get_value(section, "collision", {})
	var atlas := PropAtlas.new()
	atlas.texture = texture
	for sprite in PropSlicer.slice(texture.get_image(), size):
		var key := "%d,%d" % [sprite.rect.position.x, sprite.rect.position.y]
		var id := StringName(names.get(key, "%s_%s" % [sheet, key.replace(",", "_")]))
		if key in skip or String(id) in skip:
			continue
		var prop := _prop(id, sprite, on_water, walkable, blocking, collisions)
		atlas.tiles[id] = sprite.rect
		result.props.append(prop)
		var rule := PropRule.new()
		rule.prop = prop
		var defaults := _default_rule(prop)
		rule.density = densities.get(String(id), defaults[0])
		rule.clustering = clusterings.get(String(id), defaults[1])
		if rule.density > 0.0:
			rules.append(rule)
		if String(id) in border_ids:
			border.append(prop)
		result.report.append("  %-22s %s  %dx%d  %s  collision %s" % [id, key, prop.size.x, prop.size.y,
			"water" if on_water else ("blocks" if prop.blocking else "walkable"), prop.collision_size])
	result.atlases.append(atlas)
	result.atlas_names.append(sheet)


static func _prop(id: StringName, sprite: PropSlicer.Sprite, on_water: bool, walkable: Array, blocking: Array,
		collisions: Dictionary) -> PropDef:
	var prop := PropDef.new()
	prop.id = id
	prop.size = sprite.rect.size
	prop.placement = PropDef.Placement.WATER if on_water else PropDef.Placement.LAND
	if String(id) in blocking:
		prop.blocking = true
	elif on_water or String(id) in walkable:
		prop.blocking = false
	else:
		prop.blocking = prop.size.x > 1 or prop.size.y > 1 or sprite.coverage >= PropSlicer.SOLID_COVERAGE
	if not prop.blocking:
		prop.collision_size = Vector2.ZERO
	elif collisions.has(String(id)):
		prop.collision_size = collisions[String(id)]
	else:
		# The box covers most of the base, so characters brush past its edges.
		var width := clampf(snappedf(sprite.base_width * 0.85, 0.05), 0.25, prop.size.x - 0.1)
		prop.collision_size = Vector2(width, clampf(snappedf(width * 0.6, 0.05), 0.25, 0.5))
	prop.collision_lift = snappedf(sprite.gap, 0.05)
	return prop


static func _default_rule(prop: PropDef) -> Array:
	if prop.placement == PropDef.Placement.WATER:
		return WATER_RULE
	if not prop.blocking:
		return PLANT_RULE
	if prop.size.y >= 3:
		return HUGE_TREE_RULE
	return TREE_RULE if prop.size.y >= 2 else SOLID_RULE


## Blocking land props at least two cells tall, biggest first.
static func _default_border(props: Array[PropDef]) -> Array[PropDef]:
	var trees: Array[PropDef] = []
	for prop in props:
		if prop.blocking and prop.placement == PropDef.Placement.LAND and prop.size.y >= 2:
			trees.append(prop)
	trees.sort_custom(func(a: PropDef, b: PropDef) -> bool: return a.size.x * a.size.y > b.size.x * b.size.y)
	return trees


## The existing biome file keeps its generation parameters; a new one copies the template.
static func _biome(cfg: ConfigFile, id: StringName, out: String) -> BiomeData:
	var path := out.path_join("biomes/%s.tres" % id)
	var biome: BiomeData
	if ResourceLoader.exists(path):
		biome = load(path)
	elif cfg.has_section_key("biome", "template"):
		biome = (load(cfg.get_value("biome", "template")) as BiomeData).duplicate()
	else:
		biome = BiomeData.new()
	biome.id = id
	biome.display_name = cfg.get_value("biome", "display_name", biome.display_name if biome.display_name != "" else String(id))
	biome.tint = cfg.get_value("biome", "tint", biome.tint)
	return biome
