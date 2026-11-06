extends SceneTree
## Imports a biome from a folder of tile sheets (see BiomeImporter, docs/biome_import.md).
## Run after new images were imported by the editor (or `godot --headless --import`):
##   godot --headless --path . -s res://tools/import_biome.gd -- res://tiles/biomes/<id> [--dry-run] [--out=res://data]


func _init() -> void:
	var folder := ""
	var out := "res://data"
	var dry_run := false
	for arg in OS.get_cmdline_user_args():
		if arg == "--dry-run":
			dry_run = true
		elif arg.begins_with("--out="):
			out = arg.get_slice("=", 1)
		else:
			folder = arg
	if folder == "":
		printerr("usage: -- res://path/to/biome_folder [--dry-run] [--out=res://data]")
		quit(2)
		return
	var result := BiomeImporter.run(folder, out)
	for line in result.report:
		print(line)
	for error in result.errors:
		printerr("ERROR: " + error)
	if not result.errors.is_empty():
		quit(1)
		return
	if dry_run:
		print("dry run: nothing written")
	else:
		var err := BiomeImporter.save(result, out)
		if err != OK:
			printerr("ERROR: saving failed: %s" % error_string(err))
			quit(1)
			return
		print("written: %s/biomes/%s.tres" % [out, result.biome.id])
	quit(0)
