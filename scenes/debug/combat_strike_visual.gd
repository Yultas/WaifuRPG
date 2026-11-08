class_name CombatStrikeVisual
extends Node2D
## Presentation of an existing strike's circle, in its parent's local pixel space.
## The hitbox owns this node; its authoritative remaining ticks drive the animation.

const SEGMENTS := 32

var _slash: Node2D
var _burst := false


func setup(radius_pixels: float, direction: Vector2, burst: bool) -> void:
	_burst = burst
	rotation = direction.angle()
	# Readable over both actors and tall props, regardless of the strike's Y position.
	z_index = 1
	var accent := Color(0.3, 0.9, 1.0) if burst else Color(1.0, 0.78, 0.2)
	var area := Polygon2D.new()
	var area_points := _arc(radius_pixels, 0.0, TAU)
	# Polygon2D closes itself; the arc's near-duplicate endpoint prevents triangulation.
	area_points.resize(SEGMENTS)
	area.polygon = area_points
	area.color = Color(accent, 0.18)
	add_child(area)
	var rim := _arc(radius_pixels * 0.96, 0.0, TAU)
	_add_line(self, rim, radius_pixels * 0.08, Color(0.12, 0.08, 0.16, 0.9))
	_add_line(self, rim, radius_pixels * 0.035, Color(accent, 0.8))
	_slash = Node2D.new()
	add_child(_slash)
	var points := _arc(radius_pixels * 0.82, 0.0 if burst else -0.9,
			TAU if burst else 0.9)
	_add_line(_slash, points, radius_pixels * 0.30, Color(0.12, 0.08, 0.16, 0.95))
	_add_line(_slash, points, radius_pixels * 0.23, accent)
	_add_line(_slash, points, radius_pixels * 0.09, Color.WHITE)
	present(1, 1)


## Only changes drawing: no processing callback, timer, collision, or damage delivery.
func present(remaining_ticks: int, lifetime_ticks: int) -> void:
	var progress := 1.0 - float(remaining_ticks) / float(lifetime_ticks)
	modulate.a = 1.0 - progress * 0.7
	if _burst:
		_slash.scale = Vector2.ONE * lerpf(0.7, 1.0, progress)
	else:
		_slash.rotation = lerpf(-0.65, 0.65, progress)


func _arc(radius: float, start: float, end: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i: int in SEGMENTS + 1:
		var angle := lerpf(start, end, float(i) / float(SEGMENTS))
		points.append(Vector2.from_angle(angle) * radius)
	return points


func _add_line(parent: Node2D, points: PackedVector2Array, width_pixels: float,
		color: Color) -> void:
	var line := Line2D.new()
	line.points = points
	line.width = width_pixels
	line.default_color = color
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	parent.add_child(line)
