extends SceneTree
## Real mouse events must produce visible strikes even when no enemy is in range.
## Run: godot --headless --fixed-fps 60 --path . -s res://tests/test_combat_feedback.gd

const PREVIEW_SCENE := preload("res://scenes/debug/dungeon_preview.tscn")

var _preview: Node2D
var _failures := 0
var _attacks := 0
var _skills := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	_preview = PREVIEW_SCENE.instantiate()
	root.add_child(_preview)
	await _frames(5)
	physics_frame.connect(_guard_enemies)
	_party().controllers[0].attack_fired.connect(_on_attack)
	_party().controllers[0].skill_fired.connect(_on_skill)
	await _test_mouse_hit()
	await _test_mouse_whiff_and_room_change()
	await _test_skill_feedback()
	_mouse(MOUSE_BUTTON_LEFT, false)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	physics_frame.disconnect(_guard_enemies)
	_preview.queue_free()
	await _frames(2)
	print("ALL PASSED" if _failures == 0 else "FAILED: %d problem(s)" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_mouse_hit() -> void:
	var party := _party()
	var view: CombatHeroView = (_preview.get("_views") as Array)[0]
	var enemy: BasicEnemy = (_preview.get("_enemies") as Array)[0]
	var direction := party.controllers[0].facing
	enemy.position = view.position + direction * 1.2 * view.pixels_per_meter
	enemy.velocity = Vector2.ZERO
	await _frames(2)
	var hp_before := enemy.combat.hp
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(2)
	_expect(_attacks == 1, "mouse: one LMB press must fire exactly one attack")
	_expect(is_equal_approx(enemy.combat.hp, hp_before - 20.0),
			"mouse: in-range enemy must take one 20-damage hit, got %.1f" % enemy.combat.hp)
	var strike := _live_strike("mouse hit")
	if strike != null:
		_expect(_has_visible_geometry(strike), "mouse hit: strike has no visible renderable geometry")
		var shape: CollisionShape2D = strike.get_child(0)
		_expect(strike.position.is_equal_approx((party.controllers[0].position
				+ direction * 0.9) * view.pixels_per_meter), "mouse hit: strike left its facing offset")
		_expect(is_equal_approx((shape.shape as CircleShape2D).radius, 0.9 * view.pixels_per_meter),
				"mouse hit: melee collision radius changed")
		var remaining: int = (_preview.get("_strikes") as Array)[0].ticks
		await _frames(remaining - 1)
		_expect(is_instance_valid(strike) and _has_visible_geometry(strike),
				"mouse: feedback vanished before the last active tick")
		await _frames(2)
		_expect((_preview.get("_strikes") as Array).is_empty(), "mouse: strike exceeded eight ticks")
	# Keep holding beyond both the active window and recovery: no autoattack or repeat hit.
	await _frames(45)
	_expect(_attacks == 1, "mouse: holding LMB repeated the attack")
	_expect(is_equal_approx(enemy.combat.hp, hp_before - 20.0), "mouse: strike hit the same enemy twice")
	_expect((_preview.get("_strikes") as Array).is_empty(), "mouse: strike outlived its active window")
	_expect(not is_instance_valid(strike), "mouse: expired strike and its feedback were not freed")
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(2)


func _test_mouse_whiff_and_room_change() -> void:
	var party := _party()
	# Every enemy is safely out of this attack's circle, independently of room geometry.
	var snapshots: Array[float] = []
	for enemy: BasicEnemy in _preview.get("_enemies"):
		enemy.position = Vector2(-10000.0, -10000.0)
		snapshots.append(enemy.combat.hp)
	await _frames(2)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(2)
	_mouse(MOUSE_BUTTON_LEFT, false)
	_expect(_attacks == 2, "whiff: second physical LMB press did not fire")
	var strike := _live_strike("whiff")
	if strike != null:
		_expect(_has_visible_geometry(strike), "whiff: strike has no visible renderable geometry")
	for i: int in snapshots.size():
		var enemy: BasicEnemy = (_preview.get("_enemies") as Array)[i]
		_expect(is_equal_approx(enemy.combat.hp, snapshots[i]), "whiff: distant enemy took damage")
	var room: RoomData = _preview.get("_room")
	var dir: int = room.neighbors.keys()[0]
	var next: RoomData = _preview.get("_dungeon").neighbor(room, dir)
	_preview.call("_show_room", next)
	_expect((_preview.get("_strikes") as Array).is_empty(), "room: strike survived room transition")
	await _frames(2)
	_expect(not is_instance_valid(strike), "room: old strike and its feedback were not freed")
	# Recovery carries across a room transition; wait for readiness rather than changing it.
	var waited := 0
	while party.active_state().action != HeroCombatState.Action.IDLE and waited < 90:
		await _frames(1)
		waited += 1
	_expect(party.active_state().action == HeroCombatState.Action.IDLE, "room: recovery did not finish")


func _test_skill_feedback() -> void:
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(2)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	var waited := 0
	while _skills == 0 and waited < 90:
		await _frames(1)
		waited += 1
	_expect(_skills == 1, "skill: physical RMB press did not fire the skill")
	var strike := _live_strike("skill")
	if strike != null:
		_expect(_has_visible_geometry(strike), "skill: burst has no visible renderable geometry")
		var renderer: RoomTileRenderer = _preview.get("_renderer")
		var shape: CollisionShape2D = strike.get_child(0)
		_expect(is_equal_approx((shape.shape as CircleShape2D).radius,
				2.6 * renderer.local_pixels_per_meter), "skill: burst collision radius changed")
	await _frames(5)
	_expect((_preview.get("_strikes") as Array).is_empty(), "skill: burst outlived its active window")
	_expect(not is_instance_valid(strike), "skill: expired burst and its feedback were not freed")


func _live_strike(context: String) -> Hitbox2D:
	var strikes: Array = _preview.get("_strikes")
	_expect(strikes.size() == 1, "%s: expected one live strike, got %d" % [context, strikes.size()])
	return strikes[0].node if strikes.size() == 1 else null


## Accept actual renderable nodes, never CollisionShape2D's editor-only debug outline.
func _has_visible_geometry(node: Node) -> bool:
	if node is CanvasItem:
		if not node.is_visible_in_tree() or node.modulate.a <= 0.0:
			return false
		if node is Polygon2D and node.polygon.size() >= 3 and node.color.a > 0.0:
			var triangles := Geometry2D.triangulate_polygon(node.polygon)
			_expect(not triangles.is_empty(), "feedback: visible fill polygon does not triangulate")
			return not triangles.is_empty()
		if node is Line2D and node.points.size() >= 2 and node.width > 0.0 \
				and node.default_color.a > 0.0:
			return true
	for child: Node in node.get_children():
		if _has_visible_geometry(child):
			return true
	return false


func _guard_enemies() -> void:
	for enemy: BasicEnemy in _preview.get("_enemies"):
		enemy.combat.statuses.apply(CombatTypes.Status.STUN, 1, -1)
		enemy.velocity = Vector2.ZERO


func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)


func _on_attack(_attack: AttackDefinition, _origin: Vector2, _direction: Vector2) -> void:
	_attacks += 1


func _on_skill(_attack: AttackDefinition, _origin: Vector2, _direction: Vector2) -> void:
	_skills += 1


func _party() -> PartyController:
	return _preview.get("_party")


func _frames(count: int) -> void:
	for i: int in count:
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr(message)
