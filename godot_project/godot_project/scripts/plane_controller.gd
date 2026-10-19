extends Node3D
## Arcade flight model for the Blender plane. Nose points to -Z (Godot forward).
##  W / Up = dive    S / Down = climb    A / Left, D / Right = bank & turn
##  Shift = boost (afterburner + sonic boom)    Ctrl = airbrake (flare + stop)
##  Space = barrel roll
##
## Jet-fighter combos:
##  S + Space   Immelmann - half loop up, half roll out. Reverses heading, gains height.
##  W + Space   Split-S   - half roll, half loop down. Reverses heading, gains speed.
##  Tab         Cobra     - nose swings past vertical while the plane keeps flying
##                          straight, bleeding speed, then snaps back.
##
## Steering is deliberately heavy: every stick input goes through a short delay
## line and an actuator lag, and both stretch with the wind load. Gusts have to
## be anticipated, not reacted to.

var terrain: Node3D
var speed := 75.0
var pitch := 0.0
var yaw := 0.0
var roll := 0.0

## 0..1, how far into boost the plane is (follows the real speed, so it ramps
## up and fades out smoothly). The camera director reads it.
var boost_amount := 0.0
## 0..1, how far below cruise the plane has slowed (airbrake, cobra, headwind).
var brake_amount := 0.0
## 0..1 envelopes of the combo currently flying (camera pulls back for them).
var cobra_amount := 0.0
var maneuver_amount := 0.0
## 0..1, how heavy the air feels right now (wind + turbulence).
var inertia_load := 0.0
## 0..1, rough g-load (drives wingtip vapour and camera shake).
var g_pull := 0.0
## The attitude the plane is actually flying along. The visible model can be
## tipped past this (cobra), so the camera and the motion use this one.
var flight_basis := Basis.IDENTITY

signal scraped(dt: float)
signal barrel_rolled
signal snap_rolled(dir: float)
signal maneuver_started(maneuver: String)
signal maneuver_denied(reason: String)

## External influences, rewritten every frame by wind / hazards / enemies.
var wind_push := Vector3.ZERO      # m/s of drift
var wind_torque := Vector3.ZERO    # rad/s disturbance (pitch, yaw, roll)
var control_authority := 1.0       # < 1 = mushy controls (turbulence)
var speed_scale := 1.0             # < 1 = slowed (rain, headwind)
var confusion := 0.0               # 0..1, mentis sonic confuser

## Movement-pattern read-outs (the mentis lock logic reads jink).
var jink := 0.0
var yaw_rate := 0.0

enum Move { NONE, IMMELMANN, SPLIT_S, COBRA }

var _t := 0.0
var _spin := 0.0
var _spin_t := -1.0
var _spin_dir := 1.0
var _roll_cd := 0.0
var _snap_e := 0.0
var _snap_dir := 1.0
var _snap_cd := 0.0
var _last_tap_dir := 0.0
var _last_tap_ms := -10000
var _bank_sign := 0.0

# Inertial control pipeline.
var _hist: Array[Vector3] = []     # (time, pitch_in, roll_in) delay line
var _cmd_pitch := 0.0
var _cmd_roll := 0.0
var _load := 0.0
var pitch_vel := 0.0
var roll_vel := 0.0
var yaw_vel := 0.0

# Combo state.
var _move: Move = Move.NONE
var _move_t := 0.0
var _move_cd := 0.0
var _move_m := Basis.IDENTITY      # loop rotation, expressed in the yaw frame
var _loop_angle := 0.0
var _roll_angle := 0.0
var _cobra := 0.0                  # visual nose-up angle (rad)

const CRUISE := 75.0
const BOOST := 135.0
const BRAKE := 45.0

# Combo timing (seconds) and tuning.
const COMBO_COOLDOWN := 2.5
const IMMELMANN_LOOP := 1.7
const IMMELMANN_ROLL_START := 1.45
const IMMELMANN_ROLL := 0.6
const IMMELMANN_TOTAL := 2.05
const SPLITS_ROLL := 0.55
const SPLITS_LOOP_START := 0.4
const SPLITS_LOOP := 1.5
const SPLITS_TOTAL := 1.95
const COBRA_RISE := 0.45
const COBRA_HOLD := 0.5
const COBRA_FALL := 0.7
const COBRA_TOTAL := 1.65
const COBRA_MAX := 1.85            # ~106 degrees
const CEILING := 900.0

# ---------------------------------------------------------
# Boost VFX tuning (distances are in the plane's local space)
# ---------------------------------------------------------
const NOSE_OFFSET := Vector3(0.0, 0.0, -5.0)   # nose tip; nose points to -Z
const CONE_LENGTH := 18.0                      # shock cone, trailing behind the nose
const CONE_RADIUS := 6.0                       # widest part of the cone (make it clear the wings)
const STREAK_RADIUS := 7.0                     # air streaks rushing past
const BOOM_COOLDOWN := 0.35                    # min seconds between booms
## Must be HIGHER than the painterly post pass's render_priority (main.gd sets 100),
## otherwise the post pass paints over the effect and it never shows.
const VFX_PRIORITY := 110

const CONE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float cone_height = 18.0;
uniform vec3 tint : source_color = vec3(1.0, 0.86, 0.72);

varying float along;   // 0 at the nose tip, 1 at the wide back end

void vertex() {
	along = clamp((cone_height * 0.5 - VERTEX.y) / cone_height, 0.0, 1.0);
}

void fragment() {
	float fres = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.0);
	// Pressure bands sliding backward along the cone.
	float bands = 0.5 + 0.5 * sin((along * 9.0 - TIME * 3.5) * 6.2831853);
	float fade_in = smoothstep(0.0, 0.10, along);
	float fade_out = 1.0 - smoothstep(0.45, 1.0, along);
	float a = (0.10 + 0.90 * fres) * (0.35 + 0.65 * bands) * fade_in * fade_out;
	ALBEDO = tint * (1.0 + fres);
	ALPHA = clamp(a * intensity, 0.0, 1.0);
}
"""

const RING_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;

uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform vec3 tint : source_color = vec3(1.0, 0.92, 0.8);
uniform float thickness = 0.09;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float edge = 0.88;
	float ring = smoothstep(edge - thickness, edge, r) * (1.0 - smoothstep(edge, edge + thickness * 0.5, r));
	float glow = smoothstep(0.0, edge, r) * 0.15 * (1.0 - smoothstep(edge, 1.0, r));
	ALBEDO = tint;
	ALPHA = clamp((ring + glow) * fade, 0.0, 1.0);
}
"""

# Afterburner plume, drawn at the tail (+Z). Tune TAIL_OFFSET to your model.
const FLAME_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float cone_height = 7.0;
uniform vec3 core : source_color = vec3(1.0, 0.95, 0.82);
uniform vec3 edge : source_color = vec3(1.0, 0.46, 0.14);

varying float along;   // 0 at the nozzle, 1 at the plume tip

void vertex() {
	along = clamp((cone_height * 0.5 - VERTEX.y) / cone_height, 0.0, 1.0);
}

void fragment() {
	float fres = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 1.5);
	float flick = 0.78 + 0.22 * sin(TIME * 62.0 + along * 21.0) * sin(TIME * 37.0);
	float diamonds = 0.65 + 0.35 * pow(abs(sin(along * 16.0 - TIME * 4.0)), 3.0);
	vec3 col = mix(core, edge, smoothstep(0.0, 0.8, along));
	float a = (0.25 + 0.75 * (1.0 - fres)) * (1.0 - along) * flick * diamonds;
	ALBEDO = col * (1.2 + (1.0 - along));
	ALPHA = clamp(a * intensity, 0.0, 1.0);
}
"""

const TAIL_OFFSET := Vector3(0.0, 0.0, 5.0)    # engine nozzle; tail points to +Z
const FLAME_LENGTH := 7.0
const FLAME_RADIUS := 1.1
const WING_TIP := 4.5                          # wingtip vapour, +/- X
const AIRBRAKE_ROOT := Vector3(1.4, 0.45, 0.6) # hinge of each airbrake panel
const AIRBRAKE_SIZE := Vector3(2.6, 0.07, 1.3)
const AIRBRAKE_MAX_DEG := 62.0

var _cone: MeshInstance3D
var _cone_mat: ShaderMaterial
var _streaks: CPUParticles3D
var _ring_shader: Shader
var _shift_was_down := false
var _ctrl_was_down := false
var _boom_cooldown := 0.0
var _trickle := 0.0

var _model: Node3D                              # pivot the Blender scene lives in
var _flame: MeshInstance3D
var _flame_mat: ShaderMaterial
var _flame_light: OmniLight3D
var _vapor: Array[CPUParticles3D] = []
var _panels: Array[Node3D] = []
var _airbrake := 0.0
var _kick := 0.0                                # +1 boost punch, -1 brake flare
var _model_pitch := 0.0


func _ready() -> void:
	_ring_shader = Shader.new()
	_ring_shader.code = RING_SHADER
	_make_model()
	_build_cone()
	_build_streaks()
	_build_flame()
	_build_vapor()
	_build_airbrakes()


func _make_model() -> void:
	if _model != null:
		return
	_model = Node3D.new()
	_model.name = "Model"
	add_child(_model)


func setup(scene: PackedScene) -> void:
	_make_model()
	_model.add_child(scene.instantiate())


func _axis(neg: Array, pos: Array) -> float:
	var v := 0.0
	for k in pos:
		if Input.is_key_pressed(k):
			v += 1.0
	for k in neg:
		if Input.is_key_pressed(k):
			v -= 1.0
	return clampf(v, -1.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_SPACE:
			_space_pressed()
		KEY_A, KEY_LEFT:
			_tap(-1.0)
		KEY_D, KEY_RIGHT:
			_tap(1.0)


## Tab is read in _input so the UI focus system never swallows it.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.pressed and not k.echo and k.keycode == KEY_TAB:
		_try_cobra()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------
# Space: barrel roll, or a combo when a pitch key is held
# ---------------------------------------------------------

func _space_pressed() -> void:
	if _move != Move.NONE:
		return
	var climb: bool = Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)
	var dive: bool = Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)
	if climb == dive or _move_cd > 0.0 or _spin_t >= 0.0:
		_try_barrel_roll()
		return

	if climb:
		# Immelmann climbs about two loop radii; keep clear of the ceiling.
		if position.y > CEILING - 160.0:
			maneuver_denied.emit("TOO HIGH FOR IMMELMANN")
			return
		_start_move(Move.IMMELMANN, "IMMELMANN")
	else:
		# Split-S dives about two loop radii; it needs real air under it.
		var agl: float = 9999.0
		if terrain:
			agl = position.y - float(terrain.call("height_at", position.x, position.z))
		var radius: float = maxf(speed, CRUISE) / (PI / SPLITS_LOOP)
		if agl < radius * 2.2 + 110.0:
			maneuver_denied.emit("TOO LOW FOR SPLIT-S")
			return
		_start_move(Move.SPLIT_S, "SPLIT-S")


func _try_cobra() -> void:
	if _move != Move.NONE or _move_cd > 0.0 or speed < 30.0:
		return
	_start_move(Move.COBRA, "COBRA")


func _start_move(m: Move, label: String) -> void:
	_move = m
	_move_t = 0.0
	_loop_angle = 0.0
	_roll_angle = 0.0
	jink = minf(jink + 1.5, 1.5)
	confusion = maxf(confusion - 0.4, 0.0)
	maneuver_started.emit(label)


func _end_move() -> void:
	_move = Move.NONE
	_move_t = 0.0
	_move_m = Basis.IDENTITY
	_loop_angle = 0.0
	_roll_angle = 0.0
	_cobra = 0.0
	_move_cd = COMBO_COOLDOWN


## Both loop combos end pointing the other way, upright. Bake that into yaw.
func _finish_reverse() -> void:
	yaw += PI
	_end_move()


func _ease(u: float) -> float:
	return lerpf(u, u * u * (3.0 - 2.0 * u), 0.4)


## Advances the active combo. Returns a multiplier for the target speed.
func _update_move(delta: float) -> float:
	var mult := 1.0
	match _move:
		Move.IMMELMANN:
			_move_t += delta
			var u1: float = clampf(_move_t / IMMELMANN_LOOP, 0.0, 1.0)
			var u2: float = clampf((_move_t - IMMELMANN_ROLL_START) / IMMELMANN_ROLL, 0.0, 1.0)
			_loop_angle = PI * _ease(u1)
			_roll_angle = PI * smoothstep(0.0, 1.0, u2)
			_move_m = Basis(Vector3.RIGHT, _loop_angle) * Basis(Vector3.BACK, _roll_angle)
			mult = 1.0 - 0.22 * sin(PI * u1)
			maneuver_amount = sin(PI * clampf(_move_t / IMMELMANN_TOTAL, 0.0, 1.0))
			if _move_t >= IMMELMANN_TOTAL:
				_finish_reverse()
		Move.SPLIT_S:
			_move_t += delta
			var ur: float = clampf(_move_t / SPLITS_ROLL, 0.0, 1.0)
			var ul: float = clampf((_move_t - SPLITS_LOOP_START) / SPLITS_LOOP, 0.0, 1.0)
			_roll_angle = PI * smoothstep(0.0, 1.0, ur)
			_loop_angle = PI * _ease(ul)
			_move_m = Basis(Vector3.BACK, _roll_angle) * Basis(Vector3.RIGHT, _loop_angle)
			mult = 1.0 + 0.2 * sin(PI * ul)
			maneuver_amount = sin(PI * clampf(_move_t / SPLITS_TOTAL, 0.0, 1.0))
			if _move_t >= SPLITS_TOTAL:
				_finish_reverse()
		Move.COBRA:
			_move_t += delta
			var prof := 0.0
			if _move_t < COBRA_RISE:
				var ur2: float = _move_t / COBRA_RISE
				prof = 1.0 - pow(1.0 - ur2, 3.0)
			elif _move_t < COBRA_RISE + COBRA_HOLD:
				var h: float = (_move_t - COBRA_RISE) / COBRA_HOLD
				prof = 1.0 - 0.05 * sin(h * TAU)
			else:
				var uf: float = clampf((_move_t - COBRA_RISE - COBRA_HOLD) / COBRA_FALL, 0.0, 1.0)
				prof = 1.0 - smoothstep(0.0, 1.0, uf)
			_cobra = COBRA_MAX * prof
			cobra_amount = prof
			maneuver_amount = prof
			mult = 1.0 - 0.55 * minf(prof * 1.2, 1.0)
			if _move_t >= COBRA_TOTAL:
				_end_move()
		_:
			maneuver_amount = move_toward(maneuver_amount, 0.0, 3.0 * delta)
			cobra_amount = move_toward(cobra_amount, 0.0, 3.0 * delta)
	return mult


## Space: full aileron roll. Breaks mentis lock and clears part of a confusion.
func _try_barrel_roll() -> void:
	if _roll_cd > 0.0 or _spin_t >= 0.0 or _move != Move.NONE:
		return
	_roll_cd = 1.6
	_spin_t = 0.0
	_spin_dir = -1.0 if roll < -0.1 else 1.0
	jink = minf(jink + 1.0, 1.5)
	confusion = maxf(confusion - 0.4, 0.0)
	speed += 8.0
	barrel_rolled.emit()


## Double-tap A/D: a quick snap-turn flick.
func _tap(dir: float) -> void:
	if _move != Move.NONE:
		return
	var now: int = Time.get_ticks_msec()
	if dir == _last_tap_dir and now - _last_tap_ms < 260 and _snap_cd <= 0.0:
		_snap_dir = dir
		_snap_e = 1.0
		_snap_cd = 0.9
		_last_tap_ms = -10000
		jink = minf(jink + 0.3, 1.5)
		snap_rolled.emit(dir)
		return
	_last_tap_dir = dir
	_last_tap_ms = now


func _process(delta: float) -> void:
	_t += delta
	_roll_cd = maxf(_roll_cd - delta, 0.0)
	_snap_cd = maxf(_snap_cd - delta, 0.0)
	_move_cd = maxf(_move_cd - delta, 0.0)

	var pitch_in := _axis([KEY_W, KEY_UP], [KEY_S, KEY_DOWN])
	var roll_in := _axis([KEY_D, KEY_RIGHT], [KEY_A, KEY_LEFT])

	# Sonic confuser: the pitch wobbles and the bank input flips and jitters.
	if confusion > 0.0:
		confusion = maxf(confusion - 0.22 * delta, 0.0)
		pitch_in = clampf(pitch_in + sin(_t * 11.0) * 0.8 * confusion, -1.0, 1.0)
		if confusion > 0.5:
			roll_in = clampf(-roll_in * 0.6 + sin(_t * 7.0) * 0.6, -1.0, 1.0)

	# A committed combo ignores the stick (cobra still lets you bank).
	var loop_lock: bool = _move == Move.IMMELMANN or _move == Move.SPLIT_S
	if loop_lock:
		pitch_in = 0.0
		roll_in = 0.0
	elif _move == Move.COBRA:
		pitch_in = 0.0

	# --- Inertial control pipeline ------------------------------------
	# 1. How heavy is the air? Gusts, turbulence and mushy authority all add up.
	var wl: float = wind_push.length() / 22.0 * 0.5 + wind_torque.length() / 0.8 * 0.6 \
		+ (1.0 - control_authority) * 0.8
	_load = lerpf(_load, clampf(wl, 0.0, 1.0), 1.0 - exp(-2.5 * delta))
	inertia_load = _load

	# 2. Delay line: the plane acts on what you did a moment ago.
	_hist.append(Vector3(_t, pitch_in, roll_in))
	var lag_s: float = lerpf(0.03, 0.17, _load)
	while _hist.size() > 2 and _hist[1].x <= _t - lag_s:
		_hist.pop_front()
	var held: Vector3 = _hist[0]

	# 3. Actuator lag: surfaces move toward the held command, not instantly.
	var servo: float = 1.0 - exp(-lerpf(26.0, 6.0, _load) * delta)
	_cmd_pitch = lerpf(_cmd_pitch, held.y, servo)
	_cmd_roll = lerpf(_cmd_roll, held.z, servo)

	var auth: float = control_authority
	var prev_yaw: float = yaw

	# 4. Mass: angular rate follows the command through a heavy lag, and gust
	# torque arrives through the same lag so it builds instead of snapping.
	var mass_k: float = lerpf(12.0, 3.4, _load)
	var want_rate: float = _cmd_pitch * 0.9 * auth + wind_torque.x
	pitch_vel = lerpf(pitch_vel, want_rate, 1.0 - exp(-mass_k * delta))
	pitch += pitch_vel * delta
	if loop_lock:
		pitch = lerpf(pitch, 0.0, 1.0 - exp(-9.0 * delta))
	elif absf(_cmd_pitch) < 0.03:
		pitch = lerpf(pitch, 0.0, 1.0 - exp(-0.8 * delta))
	if absf(pitch) > 0.9:
		pitch = clampf(pitch, -0.9, 0.9)
		pitch_vel = 0.0

	# Roll is a damped spring: heavier air = lower frequency and more overshoot.
	var w_roll: float = lerpf(8.0, 3.2, _load)
	var z_roll: float = lerpf(0.85, 0.6, _load)
	var roll_target: float = _cmd_roll * 0.95 * auth
	if loop_lock:
		roll_target = 0.0
		z_roll = 1.2
	roll_vel += ((roll_target - roll) * w_roll * w_roll \
		- roll_vel * 2.0 * z_roll * w_roll + wind_torque.z * 4.0) * delta
	roll += roll_vel * delta
	if absf(roll) > 1.45:
		roll = clampf(roll, -1.45, 1.45)
		roll_vel = 0.0

	# Heading follows the bank, also lagged: no instant new headings.
	var yaw_k: float = lerpf(10.0, 3.2, _load)
	yaw_vel = lerpf(yaw_vel, sin(roll) * 0.9 + wind_torque.y, 1.0 - exp(-yaw_k * delta))
	yaw += yaw_vel * delta

	# Snap-turn flick (bypasses the lag on purpose: it is a flick).
	if _snap_e > 0.0:
		yaw -= _snap_dir * 2.0 * _snap_e * delta
		roll -= _snap_dir * 1.4 * _snap_e * delta
		_snap_e = maxf(_snap_e - 3.2 * delta, 0.0)

	# Barrel roll spin (visual and mechanical: it only rotates the basis).
	if _spin_t >= 0.0:
		_spin_t += delta
		var u: float = clampf(_spin_t / 0.75, 0.0, 1.0)
		_spin = (u * u * (3.0 - 2.0 * u)) * TAU * _spin_dir
		if u >= 1.0:
			_spin_t = -1.0
			_spin = 0.0

	# Jink: alternating hard banks (zig-zagging) build it, time bleeds it off.
	if absf(roll) > 0.4:
		var sgn: float = signf(roll)
		if _bank_sign != 0.0 and sgn != _bank_sign:
			jink = minf(jink + 0.45, 1.5)
		_bank_sign = sgn
	jink = maxf(jink - 0.2 * delta, 0.0)
	yaw_rate = (yaw - prev_yaw) / maxf(delta, 0.0001)

	# --- Combos ---------------------------------------------------------
	var speed_mult: float = _update_move(delta)
	var loop_rate := 0.0
	if _move == Move.IMMELMANN or _move == Move.SPLIT_S:
		loop_rate = PI / (IMMELMANN_LOOP if _move == Move.IMMELMANN else SPLITS_LOOP)
	g_pull = lerpf(
		g_pull,
		clampf(absf(_cmd_pitch) * 0.5 + absf(roll_vel) * 0.1 + loop_rate / 2.4 + cobra_amount * 0.8, 0.0, 1.0),
		1.0 - exp(-6.0 * delta)
	)

	# --- Speed --------------------------------------------------------
	var target := CRUISE
	if Input.is_key_pressed(KEY_SHIFT):
		target = BOOST
	elif Input.is_key_pressed(KEY_CTRL):
		target = BRAKE
	target *= speed_scale * speed_mult
	var accel: float = 4.0 if _move == Move.COBRA else 2.0
	speed = lerpf(speed, target, 1.0 - exp(-accel * delta))
	brake_amount = clampf((CRUISE - speed) / (CRUISE - BRAKE), 0.0, 1.0)

	# --- Attitude and motion -----------------------------------------
	var base := Basis.from_euler(Vector3(pitch, yaw, roll + _spin), EULER_ORDER_YXZ)
	flight_basis = base * _move_m
	basis = flight_basis * Basis(Vector3.RIGHT, _cobra)
	var lift := Vector3.UP * 7.0 * cobra_amount
	position += (-flight_basis.z * speed + wind_push + lift) * delta

	if terrain:
		var ground: float = terrain.height_at(position.x, position.z) + 12.0
		if position.y < ground:
			position.y = ground
			pitch = maxf(pitch, 0.12)
			scraped.emit(delta)
	position.y = minf(position.y, CEILING)

	_update_boost_vfx(delta)
	_update_brake_fx(delta)
	_animate_model(delta)


# ---------------------------------------------------------
# Boost VFX: shock cone + pressure rings + rushing air streaks + afterburner
# ---------------------------------------------------------

func _update_boost_vfx(delta: float) -> void:
	boost_amount = clampf((speed - CRUISE) / (BOOST - CRUISE), 0.0, 1.0)

	# Every fresh Shift press fires the boom and punches the model forward.
	var shift_down := Input.is_key_pressed(KEY_SHIFT)
	_boom_cooldown = maxf(_boom_cooldown - delta, 0.0)
	if shift_down and not _shift_was_down and _boom_cooldown <= 0.0:
		_fire_boom()
		_boom_cooldown = BOOM_COOLDOWN
		_kick = 1.0
	_shift_was_down = shift_down

	# Shock cone grows with real speed and fades out when you let go.
	var k: float = smoothstep(0.05, 1.0, boost_amount)
	_cone.visible = k > 0.01
	if _cone.visible:
		_cone_mat.set_shader_parameter("intensity", k * 0.9)
		var width: float = lerpf(0.7, 1.0, k)
		var length_scale: float = lerpf(0.55, 1.0, k)
		_cone.scale = Vector3(width, length_scale, width)
		# Keep the apex glued to the nose while the cone stretches backward (+Z).
		_cone.position = NOSE_OFFSET + Vector3(0.0, 0.0, CONE_LENGTH * length_scale * 0.5)

	# Afterburner plume: grows and flickers with throttle.
	_flame.visible = k > 0.01
	_flame_light.visible = _flame.visible
	if _flame.visible:
		var len_scale: float = lerpf(0.35, 1.0, k) * (1.0 + 0.06 * sin(_t * 47.0))
		_flame_mat.set_shader_parameter("intensity", clampf(k * 1.1, 0.0, 1.0))
		_flame.scale = Vector3(lerpf(0.6, 1.0, k), len_scale, lerpf(0.6, 1.0, k))
		_flame.position = TAIL_OFFSET + Vector3(0.0, 0.0, FLAME_LENGTH * len_scale * 0.5)
		_flame_light.light_energy = 2.4 * k * (0.9 + 0.1 * sin(_t * 53.0))

	# Air streaks while at speed.
	_streaks.emitting = boost_amount > 0.2

	# Small pressure rings keep pulsing off the nose while boosting.
	if shift_down and boost_amount > 0.5:
		_trickle -= delta
		if _trickle <= 0.0:
			_trickle = 0.28
			_spawn_ring(9.0, 0.55, 0.35)
	else:
		_trickle = 0.0


func _fire_boom() -> void:
	_spawn_ring(26.0, 0.75, 1.0)
	_spawn_ring(42.0, 1.05, 0.7, 0.08)
	_spawn_ring(60.0, 1.40, 0.45, 0.20)


# ---------------------------------------------------------
# Brake VFX: airbrake panels, wingtip vapour, collapsing rings
# ---------------------------------------------------------

func _update_brake_fx(delta: float) -> void:
	var ctrl_down := Input.is_key_pressed(KEY_CTRL)

	# Fresh Ctrl press: the air piles up against the nose and the plane flares.
	if ctrl_down and not _ctrl_was_down:
		_kick = -1.0
		_spawn_ring(30.0, 0.55, 0.55, 0.0, true)
		_spawn_ring(18.0, 0.45, 0.4, 0.10, true)
	_ctrl_was_down = ctrl_down

	# Airbrake panels swing out with a little overshoot, then settle.
	var want: float = 1.0 if (ctrl_down or brake_amount > 0.6) else 0.0
	_airbrake = lerpf(_airbrake, want, 1.0 - exp(-(11.0 if want > _airbrake else 5.0) * delta))
	var deploy: float = _airbrake + 0.12 * sin(_airbrake * PI) * (1.0 if want > 0.5 else 0.0)
	for i in _panels.size():
		var side: float = -1.0 if i == 0 else 1.0
		_panels[i].visible = _airbrake > 0.01
		_panels[i].rotation.z = side * deg_to_rad(AIRBRAKE_MAX_DEG) * deploy

	# Vapour peels off the wingtips in hard pulls, cobras and flares.
	var vapor_on: bool = g_pull > 0.55 or cobra_amount > 0.3 or _airbrake > 0.7
	for p in _vapor:
		p.emitting = vapor_on


# ---------------------------------------------------------
# Model animation: boost lean + stretch, brake flare + squash, engine shake
# ---------------------------------------------------------

func _animate_model(delta: float) -> void:
	_kick = move_toward(_kick, 0.0, 3.2 * delta)

	var goal: float = deg_to_rad(-3.0) * boost_amount + deg_to_rad(11.0) * _airbrake
	goal += -0.10 * _kick
	_model_pitch = lerpf(_model_pitch, goal, 1.0 - exp(-11.0 * delta))
	_model.rotation.x = _model_pitch

	var sz: float = 1.0 + 0.05 * boost_amount - 0.035 * _airbrake + 0.05 * _kick
	var sxy: float = 1.0 - 0.018 * boost_amount + 0.012 * _airbrake - 0.02 * _kick
	_model.scale = Vector3(sxy, sxy, sz)

	# Engine shudder at full throttle.
	var shake: float = smoothstep(0.4, 1.0, boost_amount)
	_model.position = Vector3(sin(_t * 71.0) * 0.025, sin(_t * 59.0) * 0.02, 0.0) * shake
	_model.rotation.z = sin(_t * 43.0) * 0.012 * shake


func _build_flame() -> void:
	var shader := Shader.new()
	shader.code = FLAME_SHADER
	_flame_mat = ShaderMaterial.new()
	_flame_mat.shader = shader
	_flame_mat.render_priority = VFX_PRIORITY
	_flame_mat.set_shader_parameter("cone_height", FLAME_LENGTH)

	# Wide base at the nozzle, apex trailing toward +Z.
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = FLAME_RADIUS
	mesh.height = FLAME_LENGTH
	mesh.radial_segments = 20
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false

	_flame = MeshInstance3D.new()
	_flame.mesh = mesh
	_flame.material_override = _flame_mat
	_flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flame.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	_flame.position = TAIL_OFFSET + Vector3(0.0, 0.0, FLAME_LENGTH * 0.5)
	_flame.visible = false
	add_child(_flame)

	_flame_light = OmniLight3D.new()
	_flame_light.light_color = Color(1.0, 0.55, 0.22)
	_flame_light.omni_range = 26.0
	_flame_light.light_energy = 0.0
	_flame_light.shadow_enabled = false
	_flame_light.position = TAIL_OFFSET + Vector3(0.0, 0.0, 2.0)
	_flame_light.visible = false
	add_child(_flame_light)


func _soft_texture() -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	return t


func _build_vapor() -> void:
	var tex := _soft_texture()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	mat.albedo_color = Color(0.96, 0.92, 0.95, 1.0)
	mat.render_priority = VFX_PRIORITY
	quad.material = mat

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0),
		Color(1.0, 1.0, 1.0, 0.30),
		Color(1.0, 1.0, 1.0, 0.0),
	])

	for side in [-1.0, 1.0]:
		var p := CPUParticles3D.new()
		p.emitting = false
		p.amount = 36
		p.lifetime = 0.9
		p.local_coords = false
		p.direction = Vector3(0.0, 0.0, 1.0)
		p.spread = 4.0
		p.gravity = Vector3.ZERO
		p.initial_velocity_min = 4.0
		p.initial_velocity_max = 9.0
		p.scale_amount_min = 1.4
		p.scale_amount_max = 2.6
		p.mesh = quad
		p.color_ramp = ramp
		p.position = Vector3(float(side) * WING_TIP, 0.0, 1.5)
		add_child(p)
		_vapor.append(p)


func _build_airbrakes() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.93, 0.68, 0.34)
	mat.roughness = 0.55
	mat.emission_enabled = true
	mat.emission = Color(0.91, 0.42, 0.27)
	mat.emission_energy_multiplier = 0.35

	for side in [-1.0, 1.0]:
		var hinge := Node3D.new()
		hinge.position = Vector3(float(side) * AIRBRAKE_ROOT.x, AIRBRAKE_ROOT.y, AIRBRAKE_ROOT.z)
		hinge.visible = false
		_model.add_child(hinge)

		var panel := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = AIRBRAKE_SIZE
		panel.mesh = box
		panel.material_override = mat
		panel.position = Vector3(float(side) * AIRBRAKE_SIZE.x * 0.5, 0.0, 0.0)
		panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hinge.add_child(panel)
		_panels.append(hinge)


## One expanding shockwave ring. It is left behind in world space (top_level)
## while the plane flies on, so it reads as air being torn open. With
## inward = true it collapses onto the nose instead (the "stopping" ring).
func _spawn_ring(radius: float, duration: float, strength: float, delay: float = 0.0, inward: bool = false) -> void:
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if not is_inside_tree():
			return

	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mi.mesh = quad

	var mat := ShaderMaterial.new()
	mat.shader = _ring_shader
	mat.render_priority = VFX_PRIORITY
	mat.set_shader_parameter("fade", 0.0 if inward else strength)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	add_child(mi)

	# Perpendicular to the flight direction, at the nose.
	mi.global_transform = Transform3D(global_transform.basis.orthonormalized(), to_global(NOSE_OFFSET))

	var tw := mi.create_tween().set_parallel(true)
	if inward:
		mi.scale = Vector3.ONE * radius
		tw.tween_property(mi, "scale", Vector3.ONE * 0.8, duration) \
			.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
		tw.tween_method(
			func(u: float) -> void: mat.set_shader_parameter("fade", strength * sin(u * PI)),
			0.0, 1.0, duration
		)
	else:
		mi.scale = Vector3.ONE * 0.5
		tw.tween_property(mi, "scale", Vector3.ONE * radius, duration) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tw.tween_method(
			func(v: float) -> void: mat.set_shader_parameter("fade", v),
			strength, 0.0, duration
		).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(mi.queue_free)


func _build_cone() -> void:
	var shader := Shader.new()
	shader.code = CONE_SHADER

	_cone_mat = ShaderMaterial.new()
	_cone_mat.shader = shader
	_cone_mat.render_priority = VFX_PRIORITY
	_cone_mat.set_shader_parameter("cone_height", CONE_LENGTH)

	# CylinderMesh with a zero top radius = cone, apex on +Y.
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = CONE_RADIUS
	mesh.height = CONE_LENGTH
	mesh.radial_segments = 48
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false

	_cone = MeshInstance3D.new()
	_cone.mesh = mesh
	_cone.material_override = _cone_mat
	_cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Rotate -90 deg about X so the apex (+Y) points forward (-Z), widening backward.
	_cone.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_cone.position = NOSE_OFFSET + Vector3(0.0, 0.0, CONE_LENGTH * 0.5)
	_cone.visible = false
	add_child(_cone)


func _build_streaks() -> void:
	_streaks = CPUParticles3D.new()
	_streaks.emitting = false
	_streaks.amount = 80
	_streaks.lifetime = 0.55
	_streaks.local_coords = false          # streaks stay in the air; the plane flies past them
	_streaks.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_streaks.emission_ring_axis = Vector3(0.0, 0.0, 1.0)
	_streaks.emission_ring_height = 3.0
	_streaks.emission_ring_radius = STREAK_RADIUS
	_streaks.emission_ring_inner_radius = STREAK_RADIUS * 0.45
	_streaks.direction = Vector3(0.0, 0.0, 1.0)   # drift backward
	_streaks.spread = 2.0
	_streaks.gravity = Vector3.ZERO
	_streaks.initial_velocity_min = 20.0
	_streaks.initial_velocity_max = 38.0
	_streaks.particle_flag_align_y = true         # long axis follows the motion

	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.06, 4.0, 0.06)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 0.92, 0.8, 1.0)
	mat.render_priority = VFX_PRIORITY
	mesh.material = mat
	_streaks.mesh = mesh

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0),
		Color(1.0, 1.0, 1.0, 0.8),
		Color(1.0, 1.0, 1.0, 0.0),
	])
	_streaks.color_ramp = ramp

	# Spawn a little ahead of the nose so the plane overtakes them.
	_streaks.position = NOSE_OFFSET + Vector3(0.0, 0.0, -6.0)
	add_child(_streaks)