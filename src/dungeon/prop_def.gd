class_name PropDef
extends Resource
## A decoration placed on the room grid: tree, rock, flower, lily pad...
## The footprint grows up and to the right from the anchor (bottom-left) cell.

enum Placement { LAND, WATER }

@export var id: StringName
## Cells covered by the prop. The anchor is the bottom-left cell.
@export var size := Vector2i.ONE
## The bottom row of the footprint blocks movement (trunks, rocks). Upper rows never block,
## so characters can walk behind tree crowns.
@export var blocking := true
@export var placement: Placement = Placement.LAND
## Physical collision box of a blocking prop, in meters, centered horizontally on the
## footprint's bottom row. Smaller than the cell so characters can brush past.
## Zero = no physical collider.
@export var collision_size := Vector2(0.5, 0.35)
## Gap in meters between the bottom of the cell and the bottom of the box.
@export var collision_lift := 0.1
