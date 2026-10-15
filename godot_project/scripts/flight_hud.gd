extends CanvasLayer
## Flight HUD in the game's painted-dusk language.
##
## Design rules:
##  - Quiet by default (62% opacity), brighter when you act or are in danger.
##  - One soft plum glass panel, cream type, ochre/terracotta only for state.
##  - Numbers are big, labels are small and tracked out; no boxes around text.
##  - Controls appear as key-caps for 10 seconds, then get out of the way.
##    Press H to show them again.
##
## Optional: drop a font at res://assets/fonts/hud.ttf to replace the default.

const CREAM := Color(0.97, 0.90, 0.80)
const OCHRE := Color(0.93, 0.68, 0.34)
const TERRA := Color(0.91, 0.42, 0.27)
const PLUM := Color(0.15, 0.08, 0.15)

const MAX_SPEED := 320.0
const HINT_SECONDS := 10.0

var plane: Node3D
var terrain: Node3D
var guard: Node

var _canvas: Control
var _label_font: FontVariation
var _num_font: Font
var _style := StyleBoxFlat.new()

var _t := 0.0
var _hint_t := 0.0
var _speed := 0.0
var _agl := 0.0
var _boost := 0.0
var _warn := 0.0
var _alpha := 0.62
var _min_c := 120.0
var _comfort_c := 210.0


func setup(plane_node: Node3D, terrain_node: Node3D, guard_node: Node) -> void:
	plane = plane_node
	terrain = terrain_node
	guard = guard_node


func _ready() -> void:
	layer = 1

	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_hud)
	add_child(_canvas)

	var base: Font = ThemeDB.fallback_font
	if ResourceLoader.exists("res://assets/fonts/hud.ttf"):
		base = load("res://assets/fonts/hud.ttf") as Font

	_num_font = base

	# Labels get wider letter spacing for that quiet, cinematic look.
	_label_font = FontVariation.new()
	_label_font.base_font = base
	_label_font.spacing_glyph = 2


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_H:
			_hint_t = 0.0


func _process(delta: float) -> void:
	_t += delta
	_hint_t += delta

	if not is_instance_valid(plane) or not is_instance_valid(terrain):
		return

	var pos: Vector3 = plane.global_position
	var ground: float = float(terrain.call("height_at", pos.x, pos.z))

	# Smooth the numbers so they glide instead of flickering.
	var k: float = 1.0 - exp(-8.0 * delta)
	_speed = lerpf(_speed, float(plane.get("speed")), k)
	_agl = lerpf(_agl, pos.y - ground, k)

	var urgency: float = 0.0
	if is_instance_valid(guard):
		urgency = float(guard.get("urgency"))
		_min_c = float(guard.get("min_clearance"))
		_comfort_c = float(guard.get("comfort_clearance"))

	var boosting: bool = Input.is_key_pressed(KEY_SHIFT)
	var braking: bool = Input.is_key_pressed(KEY_CTRL)

	_boost = lerpf(_boost, 1.0 if boosting else 0.0, 1.0 - exp(-5.0 * delta))
	_warn = lerpf(
		_warn, smoothstep(0.25, 0.55, urgency), 1.0 - exp(-6.0 * delta)
	)

	var active: bool = boosting or braking or urgency > 0.25
	_alpha = lerpf(
		_alpha, 1.0 if active else 0.62, 1.0 - exp(-3.0 * delta)
	)

	_canvas.queue_redraw()


# ---------------------------------------------------------
# Drawing
# ---------------------------------------------------------

func _draw_hud() -> void:
	var vp: Vector2 = _canvas.size
	var s: float = clampf(vp.y / 1080.0, 0.75, 2.0)
	var intro: float = clampf((_t - 0.4) / 1.6, 0.0, 1.0)

	_draw_flight_panel(vp, s, _alpha * intro)
	_draw_warning(vp, s, intro)
	_draw_hints(s, intro)


func _draw_flight_panel(vp: Vector2, s: float, a: float) -> void:
	var w: float = 460.0 * s
	var h: float = 82.0 * s
	var rect := Rect2(vp.x * 0.5 - w * 0.5, vp.y - h - 34.0 * s, w, h)

	_panel(rect, Color(PLUM, 0.36 * a), Color(CREAM, 0.20 * a), 18.0 * s)

	var pad: float = 28.0 * s
	var col_w: float = w * 0.5 - pad * 1.6
	var x0: float = rect.position.x + pad
	var x1: float = rect.position.x + w * 0.5 + pad * 0.6
	var mid: float = rect.position.x + w * 0.5

	_canvas.draw_line(
		Vector2(mid, rect.position.y + 16.0 * s),
		Vector2(mid, rect.end.y - 16.0 * s),
		Color(CREAM, 0.14 * a),
		1.0
	)

	_stat(x0, rect.position.y, s, a, "SPEED", str(roundi(_speed)), "m/s")
	_stat(
		x1, rect.position.y, s, a,
		"ALTITUDE", str(roundi(maxf(_agl, 0.0))), "m"
	)

	var by: float = rect.end.y - 14.0 * s

	# Speed bar warms toward ochre while boosting.
	_bar(
		x0, by, col_w, s, a,
		_speed / MAX_SPEED,
		CREAM.lerp(OCHRE, _boost)
	)

	# Altitude bar: cream when comfortable, ochre then terracotta near ground.
	var max_c: float = _comfort_c * 2.0
	var danger: float = 1.0 - smoothstep(_min_c, _comfort_c * 1.2, _agl)
	var alt_col: Color = CREAM.lerp(OCHRE, clampf(danger * 2.0, 0.0, 1.0))
	alt_col = alt_col.lerp(TERRA, clampf(danger * 2.0 - 1.0, 0.0, 1.0))

	_bar(x1, by, col_w, s, a, _agl / max_c, alt_col)

	# Ticks mark the hard floor and the comfort line.
	for mark in [_min_c, _comfort_c]:
		var tx: float = x1 + col_w * clampf(float(mark) / max_c, 0.0, 1.0)
		_canvas.draw_line(
			Vector2(tx, by - 5.0 * s),
			Vector2(tx, by + 8.0 * s),
			Color(CREAM, 0.35 * a),
			1.0
		)


func _stat(
	x: float, top: float, s: float, a: float,
	label: String, value: String, unit: String
) -> void:
	_text(_label_font, label, Vector2(x, top + 25.0 * s), 11.0 * s, Color(CREAM, 0.62 * a))

	var vsize: int = roundi(30.0 * s)
	_text(_num_font, value, Vector2(x, top + 54.0 * s), float(vsize), Color(CREAM, a))

	var wv: float = _num_font.get_string_size(
		value, HORIZONTAL_ALIGNMENT_LEFT, -1, vsize
	).x
	_text(
		_label_font, unit,
		Vector2(x + wv + 6.0 * s, top + 54.0 * s),
		12.0 * s, Color(CREAM, 0.60 * a)
	)


func _bar(
	x: float, y: float, w: float, s: float, a: float,
	fill: float, color: Color
) -> void:
	var f: float = clampf(fill, 0.0, 1.0)
	_canvas.draw_rect(Rect2(x, y, w, 3.0 * s), Color(CREAM, 0.16 * a))
	_canvas.draw_rect(Rect2(x, y, w * f, 3.0 * s), Color(color, 0.95 * a))
	_canvas.draw_circle(Vector2(x + w * f, y + 1.5 * s), 3.2 * s, Color(color, a))


func _draw_warning(vp: Vector2, s: float, intro: float) -> void:
	if _warn < 0.02:
		return

	var pulse: float = 0.65 + 0.35 * sin(_t * 7.0)
	var a: float = _warn * intro

	var w: float = 250.0 * s
	var h: float = 38.0 * s
	var rect := Rect2(vp.x * 0.5 - w * 0.5, 64.0 * s, w, h)

	_panel(
		rect,
		Color(PLUM, 0.40 * a),
		Color(TERRA, (0.55 + 0.35 * pulse) * a),
		h * 0.5
	)

	_text(
		_label_font, "TERRAIN AHEAD",
		Vector2(rect.position.x + 12.0 * s, rect.position.y + h * 0.5 + 5.0 * s),
		13.0 * s,
		Color(TERRA.lerp(CREAM, 0.35), a),
		HORIZONTAL_ALIGNMENT_CENTER, w
	)

	# Two upward chevrons: pull up.
	var cx: float = rect.position.x + 24.0 * s
	var cy: float = rect.position.y + h * 0.5
	for i in range(2):
		var y: float = cy + (4.0 - float(i) * 7.0) * s
		_canvas.draw_polyline(
			PackedVector2Array([
				Vector2(cx - 6.0 * s, y + 3.0 * s),
				Vector2(cx, y - 3.0 * s),
				Vector2(cx + 6.0 * s, y + 3.0 * s)
			]),
			Color(TERRA, a * (0.6 + 0.4 * pulse)),
			2.0 * s,
			true
		)


func _draw_hints(s: float, intro: float) -> void:
	var fade: float = 1.0 - clampf((_hint_t - HINT_SECONDS) / 1.5, 0.0, 1.0)
	var a: float = fade * intro * 0.85
	if a < 0.01:
		return

	var rows: Array = [
		[["W", "S"], "Pitch"],
		[["A", "D"], "Bank"],
		[["Shift"], "Boost"],
		[["Ctrl"], "Brake"],
		[["F1"], "Paint"],
	]

	var x: float = 30.0 * s
	var y: float = 34.0 * s

	for row in rows:
		var cx: float = x
		for key in row[0]:
			cx += _keycap(Vector2(cx, y), String(key), s, a) + 6.0 * s

		_text(
			_label_font, String(row[1]).to_upper(),
			Vector2(cx + 6.0 * s, y + 16.0 * s),
			11.0 * s, Color(CREAM, 0.80 * a)
		)
		y += 32.0 * s


func _keycap(pos: Vector2, text: String, s: float, a: float) -> float:
	var fs: float = 11.0 * s
	var tw: float = _num_font.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, roundi(fs)
	).x
	var w: float = maxf(tw + 14.0 * s, 24.0 * s)
	var rect := Rect2(pos, Vector2(w, 24.0 * s))

	_panel(rect, Color(PLUM, 0.30 * a), Color(CREAM, 0.32 * a), 6.0 * s)
	_text(
		_num_font, text,
		Vector2(rect.position.x, rect.position.y + 16.0 * s),
		fs, Color(CREAM, 0.95 * a),
		HORIZONTAL_ALIGNMENT_CENTER, w
	)
	return w


# ---------------------------------------------------------
# Primitives
# ---------------------------------------------------------

func _panel(rect: Rect2, bg: Color, border: Color, radius: float) -> void:
	_style.bg_color = bg
	_style.border_color = border
	_style.set_border_width_all(1)
	_style.set_corner_radius_all(roundi(radius))
	_style.anti_aliasing = true
	_canvas.draw_style_box(_style, rect)


func _text(
	font: Font, text: String, pos: Vector2, size: float, color: Color,
	align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
	width: float = -1.0
) -> void:
	var fs: int = roundi(size)
	# Soft plum drop shadow keeps cream type readable on the bright sky.
	_canvas.draw_string(
		font, pos + Vector2(1.5, 1.5), text, align, width, fs,
		Color(PLUM, color.a * 0.55)
	)
	_canvas.draw_string(font, pos, text, align, width, fs, color)
