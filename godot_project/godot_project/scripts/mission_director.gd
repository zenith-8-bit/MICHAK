extends CanvasLayer
## Canyon Skies narrative + mission systems. Designed to attach to main.gd at runtime.

signal mission_event(kind: String)

const CREAM := Color(0.93, 0.96, 0.96, 1.0)
const CYAN := Color(0.0, 0.94, 1.0, 1.0)
const MINT := Color(0.25, 1.0, 0.72, 1.0)
const CORAL := Color(1.0, 0.34, 0.22, 1.0)
const GLASS := Color(0.035, 0.075, 0.105, 0.92)

var plane: Node3D
var terrain: Node3D
var flock: Node3D
var main_node: Node
var checkpoint_positions: Array[Vector3] = []
var checkpoint_index := 0
var report_count := 0
var objective_index := 0
var _time := 0.0
var _intro_open := true
var _paused := false
var _message_time := 0.0
var _message := ""
var _mission_label: Label
var _status_label: Label
var _message_label: Label
var _intro_panel: PanelContainer
var _pause_panel: PanelContainer
var _root: Control
var _last_zone := "OPEN SKY"
var _fake_signal_cooldown := 0.0
var _radio_cooldown := 0.0
var _defense_cooldown := 0.0
var _defense_active := false
var _defense_pos := Vector3.ZERO
var _defense_node: Node3D
var _defense_bolt: MeshInstance3D
var _noise := FastNoiseLite.new()

var objectives := [
	"FOLLOW THE MANTA FLOCK — keep the herd in sensor range",
	"TRACE THE DWELLING — locate the fuel-bearing nesting ground",
	"REPORT THE COORDINATES — reach a wired relay checkpoint",
	"DECEIVE THE DEFENCE GRID — deploy a false signal (Q)",
	"BLIND THE RELAY — transmit protocol interference (E)",
	"BREAK THE PURSUIT — use a canyon and a hard jink",
	"EXPOSE THE POACHERS — find and disrupt their ground network"
]

func setup(plane_node: Node3D, terrain_node: Node3D, flock_node: Node3D, owner_node: Node) -> void:
	plane = plane_node
	terrain = terrain_node
	flock = flock_node
	main_node = owner_node
	process_mode = Node.PROCESS_MODE_ALWAYS
	_noise.seed = 42719
	_noise.frequency = 0.12
	_build_ui()
	_build_checkpoints()
	_build_defense()
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_mission_label = _label("", 16, CYAN)
	_mission_label.position = Vector2(28, 190)
	_mission_label.size = Vector2(510, 100)
	_root.add_child(_mission_label)
	_status_label = _label("", 13, CREAM)
	_status_label.position = Vector2(28, 292)
	_status_label.size = Vector2(510, 92)
	_root.add_child(_status_label)
	_message_label = _label("", 17, MINT)
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_message_label.position.y = 122
	_message_label.size.y = 34
	_root.add_child(_message_label)
	_intro_panel = _panel("CANYON SKIES  /  FIELD DOSSIER", "A wealthy sky-oil contractor has hired you off the books.\n\nFollow the migrating manta flocks: where they nest, volatile fuel seeps from the ground. Record the dwelling coordinates and report them through wired relay checkpoints.\n\nThe contract says nothing about the poachers, the MENTIS sonic hunters, or the automated ground defence grid. Your aircraft is unarmed. Your only weapons are flight, deception, and the terrain.\n\nKeep low only when you can control the turbulence. Storms corrupt sensors; negative-charge clouds scramble telemetry. MENTIS locks onto predictable movement. Break line-of-sight through the mountain corridors.\n\nCONTROLS  •  WASD steer  •  Shift boost  •  Ctrl brake  •  Space barrel-roll\nCOMBOS  •  S+Space Immelmann  •  W+Space Split-S  •  Tab Cobra\nQ false signal  •  E radio interference  •  R report at relay  •  Wheel focus  •  Esc pause", "BEGIN FLIGHT")
	_intro_panel.set_anchors_preset(Control.PRESET_CENTER)
	_intro_panel.position = Vector2(-300, -245)
	_intro_panel.size = Vector2(600, 490)
	_root.add_child(_intro_panel)
	var intro_button := _button("BEGIN FLIGHT", func(): _close_intro())
	_intro_panel.get_child(0).add_child(intro_button)
	_pause_panel = _panel("FLIGHT PAUSED", "Mission clock suspended. The sky is waiting.", "RESUME FLIGHT")
	_pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	_pause_panel.position = Vector2(-210, -150)
	_pause_panel.size = Vector2(420, 300)
	_pause_panel.visible = false
	_root.add_child(_pause_panel)
	_pause_panel.get_child(0).add_child(_button("RESUME FLIGHT", func(): _toggle_pause(false)))
	_pause_panel.get_child(0).add_child(_button("RESTART FLIGHT", func(): get_tree().reload_current_scene()))
	_pause_panel.get_child(0).add_child(_button("QUIT TO DESKTOP", func(): get_tree().quit()))

func _label(text_value: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text_value
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0.02, 0.03, 0.05, 0.95))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _panel(title_text: String, body: String, _button_text: String) -> PanelContainer:
	var p := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = GLASS
	style.border_color = Color(CYAN, 0.68)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 22
	style.content_margin_bottom = 22
	p.add_theme_stylebox_override("panel", style)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	p.add_child(col)
	var h := _label(title_text, 21, CYAN)
	col.add_child(h)
	var b := _label(body, 14, CREAM)
	b.custom_minimum_size.y = 130
	col.add_child(b)
	return p

func _button(caption: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = caption
	b.custom_minimum_size = Vector2(0, 38)
	b.add_theme_color_override("font_color", CREAM)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.02, 0.18, 0.22, 0.96)
	normal.border_color = CYAN
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(5)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.pressed.connect(action)
	return b

func _build_checkpoints() -> void:
	checkpoint_positions.clear()

	for p: Vector3 in [
		Vector3(0, 0, -1800),
		Vector3(1550, 0, -2900),
		Vector3(-1800, 0, -4100)
	]:
		var q: Vector3 = p
		q.y = float(terrain.call("height_at", q.x, q.z)) + 180.0
		checkpoint_positions.append(q)

		var marker := MeshInstance3D.new()
		marker.name = "WiredRelay"

		var mesh := CylinderMesh.new()
		mesh.top_radius = 4.0
		mesh.bottom_radius = 4.0
		mesh.height = 90.0
		marker.mesh = mesh


		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(CYAN, 0.65)
		mat.emission_enabled = true
		mat.emission = CYAN
		marker.material_override = mat

		marker.position = q
		terrain.add_child(marker)

func _build_defense() -> void:
	_defense_node = Node3D.new()
	_defense_node.name = "AutomatedGroundDefense"
	add_child(_defense_node)
	var base := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 4.0
	mesh.bottom_radius = 10.0
	mesh.height = 12.0
	base.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.24, 0.12, 0.15)
	mat.emission_enabled = true
	mat.emission = CORAL
	base.material_override = mat
	_defense_node.add_child(base)
	_defense_node.visible = false

func _close_intro() -> void:
	_intro_open = false
	_intro_panel.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_show_message("CONTRACT ACCEPTED  /  SIGNALS ARE LIVE", 4.0)

func _toggle_pause(value: bool) -> void:
	_paused = value
	_pause_panel.visible = value
	get_tree().paused = value
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if value or _intro_open else Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				if _intro_open:
					_close_intro()
				else:
					_toggle_pause(not _paused)
				get_viewport().set_input_as_handled()
			KEY_Q: _deploy_false_signal()
			KEY_E: _radio_interference()
			KEY_R: _report_at_checkpoint()

func _process(delta: float) -> void:
	if _intro_open or _paused or not is_instance_valid(plane):
		return
	_time += delta
	_fake_signal_cooldown = maxf(0.0, _fake_signal_cooldown - delta)
	_radio_cooldown = maxf(0.0, _radio_cooldown - delta)
	_defense_cooldown = maxf(0.0, _defense_cooldown - delta)
	_message_time = maxf(0.0, _message_time - delta)
	var pos: Vector3 = plane.global_position
	var speed := float(plane.get("speed"))
	var ground := float(terrain.call("height_at", pos.x, pos.z))
	var agl := pos.y - ground
	var nearest := {"dist": 99999.0, "pos": Vector3.ZERO}
	if is_instance_valid(flock): nearest = flock.call("nearest", pos)
	var flock_dist := float(nearest.get("dist", 99999.0))
	var zone := "OPEN SKY"
	if agl < 150.0: zone = "RIDGE TURBULENCE"
	if _noise.get_noise_2d(pos.x * 0.001, pos.z * 0.001) > 0.45: zone = "POACHER WAR ZONE"
	if agl < 90.0 and flock_dist < 500.0: zone = "MANTA FLIGHT CORRIDOR"
	if zone != _last_zone:
		_last_zone = zone
		_show_message("ZONE SHIFT  /  " + zone, 2.5)
		mission_event.emit("zone_" + zone.to_lower().replace(" ", "_"))
	if _defense_active and _defense_cooldown <= 0.0:
		_defense_active = false
		_defense_node.visible = false
	if not _defense_active and _defense_cooldown <= 0.0 and _noise.get_noise_2d(pos.x * 0.002, pos.z * 0.002) > 0.57:
		_defense_active = true
		_defense_cooldown = 8.0
		_defense_pos = Vector3(pos.x + randf_range(-240, 240), float(terrain.call("height_at", pos.x, pos.z)) + 8.0, pos.z - 220.0)
		_defense_node.global_position = _defense_pos
		_defense_node.visible = true
		_show_message("GROUND DEFENCE ACQUIRING — Q FALSE SIGNAL / E JAM RELAY", 3.0)
	var checkpoint_dist := 99999.0
	if checkpoint_positions.size() > 0:
		checkpoint_dist = pos.distance_to(checkpoint_positions[checkpoint_index % checkpoint_positions.size()])
	_mission_label.text = "FIELD TASK  %02d / %02d\n%s\n\nRELAY %02d  •  %.1f km" % [mini(objective_index + 1, objectives.size()), objectives.size(), objectives[mini(objective_index, objectives.size() - 1)], checkpoint_index + 1, checkpoint_dist / 1000.0]
	_status_label.text = "FLIGHT  %.0f m/s   •   AGL %.0f m\nMANTA SIGNAL  %.1f km\nWIND / SENSOR FIELD  %s\nFALSE SIGNAL  %s     RADIO JAM  %s\nREPORTED SITES  %d" % [speed, agl, flock_dist / 1000.0, zone, "READY" if _fake_signal_cooldown <= 0 else "RECHARGING", "READY" if _radio_cooldown <= 0 else "RECHARGING", report_count]
	_message_label.text = _message if _message_time > 0.0 else ""
	if flock_dist < 220.0 and objective_index == 0:
		objective_index = 1
		_show_message("MANTA SIGNATURE CONFIRMED — FOLLOW THEIR TURN", 4.0)
	if is_instance_valid(flock) and bool(flock.get("has_dwelling")) and objective_index == 1:
		var home: Vector3 = flock.get("dwelling_pos")
		if pos.distance_to(home) < 500.0:
			objective_index = 2
			_show_message("DWELLING FIXED — COORDINATES STORED LOCALLY", 4.0)
	if agl < 95.0 and speed > 90.0 and absf(float(plane.get("jink"))) > 0.4 and zone.find("RIDGE") >= 0:
		if objective_index < 5: objective_index = 5

func _deploy_false_signal() -> void:
	if _intro_open or _paused or _fake_signal_cooldown > 0.0: return
	_fake_signal_cooldown = 12.0
	if _defense_active:
		_defense_active = false
		_defense_node.visible = false
		objective_index = maxi(objective_index, 3)
		_show_message("FALSE BEACON ACCEPTED — DEFENCE GRID TRACKING GHOST", 4.0)
	else:
		_show_message("FALSE BEACON RELEASED — DRAWING ATTENTION OFF YOUR ROUTE", 2.5)
	mission_event.emit("false_signal")

func _radio_interference() -> void:
	if _intro_open or _paused or _radio_cooldown > 0.0: return
	_radio_cooldown = 16.0
	_defense_active = false
	_defense_node.visible = false
	objective_index = maxi(objective_index, 4)
	_show_message("PROTOCOL K-17 TRANSMITTED — LOCAL RELAY BLINDED", 3.5)
	mission_event.emit("radio_interference")

func _report_at_checkpoint() -> void:
	if _intro_open or _paused: return
	var p: Vector3 = plane.global_position
	var target: Vector3 = checkpoint_positions[checkpoint_index % checkpoint_positions.size()]
	if p.distance_to(target) > 330.0:
		_show_message("NO WIRED LINK — MOVE WITHIN 330 M OF THE RELAY", 2.5)
		return
	report_count += 1
	checkpoint_index = (checkpoint_index + 1) % checkpoint_positions.size()
	objective_index = maxi(objective_index, 2)
	_show_message("FIELD REPORT SENT  /  GPS FIX %02d ARCHIVED" % report_count, 4.0)
	mission_event.emit("checkpoint_report")

func _show_message(text_value: String, duration: float) -> void:
	_message = text_value
	_message_time = duration
