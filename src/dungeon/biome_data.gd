class_name BiomeData
extends Resource
## Generation parameters and look of one biome. Every room of a dungeon uses one biome.

@export var id: StringName
@export var display_name := ""

@export_group("Border")
@export var border_style: DungeonTypes.BorderStyle = DungeonTypes.BorderStyle.TREES
## Minimum border width in cells.
@export_range(1, 6) var border_thickness := 3
## Extra random width added along the border.
@export_range(0, 4) var border_wobble := 2
## Props that fill a TREES border, biggest first.
@export var border_props: Array[PropDef] = []

@export_group("Elevation")
@export_range(0, 2) var max_level := 1
## Approximate share of the room interior raised above the ground level.
@export_range(0.0, 0.8, 0.01) var elevation_amount := 0.2
## Share of the raised area that goes up one more level (needs max_level 2).
@export_range(0.0, 0.8, 0.01) var high_ground_amount := 0.3
@export_range(0.01, 0.3, 0.005) var elevation_frequency := 0.06
## Smaller plateaus are flattened.
@export_range(4, 64) var min_plateau_cells := 12

@export_group("Water")
## Chance that a combat room has a river.
@export_range(0.0, 1.0, 0.01) var river_chance := 0.5
## Min and max river width in cells.
@export var river_width := Vector2i(2, 3)
## Approximate share of the room interior covered by ponds.
@export_range(0.0, 0.5, 0.01) var lake_amount := 0.06
@export_range(0.01, 0.3, 0.005) var lake_frequency := 0.08
## Smaller ponds are filled with land.
@export_range(2, 64) var min_lake_cells := 6
@export_range(1, 3) var bridge_width := 2
@export_range(1, 16) var max_bridge_length := 8

@export_group("Vegetation")
## Share of land covered with lush grass (visual only).
@export_range(0.0, 1.0, 0.01) var lush_amount := 0.35
@export_range(0.01, 0.3, 0.005) var vegetation_frequency := 0.09
@export var props: Array[PropRule] = []

@export_group("Rendering")
@export var tile_theme: TileTheme
## Placeholder tint until the biome gets its own tiles.
@export var tint := Color.WHITE


## Every biome resource in a folder, sorted by file name.
static func load_all(folder := "res://data/biomes") -> Array[BiomeData]:
	var biomes: Array[BiomeData] = []
	var files := ResourceLoader.list_directory(folder)
	files.sort()
	for file in files:
		if file.ends_with(".tres"):
			var biome := load(folder.path_join(file)) as BiomeData
			if biome != null:
				biomes.append(biome)
	return biomes
