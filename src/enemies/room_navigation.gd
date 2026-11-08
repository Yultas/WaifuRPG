class_name RoomNavigation
extends NavigationRegion2D
## Navigation mesh of one room, built from RoomMap walkable cells (never from tiles), in
## the node's local pixels. Used by enemies that path through the real NavigationServer2D.
##
## Every walkable cell becomes one convex quad. Along an edge where RoomMap.can_cross() is
## true the quad reaches the cell border, so neighbour quads share the edge and the
## NavigationServer2D connects them; where can_cross() is false (cliffs, bridge sides,
## blocked cells, walls) the quad is pulled back by a small gap, larger than the server's
## edge connection margin, so the two sides never link. Bridges, stairs, props and
## elevation levels therefore obey the same movement rules as the characters (see
## RoomCollision).

const T := preload("res://src/dungeon/dungeon_types.gd")

## Fraction of a cell kept free on edges the terrain forbids to cross.
const GAP_FRACTION := 0.15


static func build_2d(map: RoomMap, pixels_per_meter: float) -> RoomNavigation:
	var nav := RoomNavigation.new()
	nav.name = "RoomNavigation"
	var cell_px := WorldUnits.CELL_SIZE * pixels_per_meter
	var gap := cell_px * GAP_FRACTION
	var vertices := PackedVector2Array()
	var polygon := NavigationPolygon.new()
	for i in map.cell_count():
		var c := map.cell(i)
		if not map.is_walkable(c):
			continue
		var x0 := float(c.x) * cell_px
		var y0 := float(c.y) * cell_px
		var x1 := x0 + cell_px
		var y1 := y0 + cell_px
		for dir in 4:
			var n := c + T.DIR_VECTORS[dir]
			var cross := map.in_bounds(n) and map.can_cross(c, dir)
			match dir:
				T.Dir.NORTH:
					y0 = y0 if cross else y0 + gap
				T.Dir.SOUTH:
					y1 = y1 if cross else y1 - gap
				T.Dir.WEST:
					x0 = x0 if cross else x0 + gap
				_:
					x1 = x1 if cross else x1 - gap
		var base := vertices.size()
		# Counter-clockwise in Godot's y-down coordinates, as NavigationServer2D requires.
		vertices.append_array([Vector2(x0, y0), Vector2(x0, y1), Vector2(x1, y1), Vector2(x1, y0)])
		polygon.add_polygon(PackedInt32Array([base, base + 1, base + 2, base + 3]))
	polygon.vertices = vertices
	nav.navigation_polygon = polygon
	return nav
