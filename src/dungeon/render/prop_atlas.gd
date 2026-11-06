class_name PropAtlas
extends Resource
## One texture with prop sprites: PropDef.id -> rectangle in tiles. The rectangle size
## must match the prop footprint.

@export var texture: Texture2D
@export var tiles: Dictionary[StringName, Rect2i] = {}
