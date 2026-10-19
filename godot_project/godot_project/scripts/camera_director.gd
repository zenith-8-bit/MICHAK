extends Node
## Chase camera + screen FX for Canyon Skies. Runs right after main.gd (priority 101).
##
##  * Spring-damped chase: the camera has mass. It lags, overshoots a little when you
##    brake, stretches away when you boost, and swings round behind turns.
##  * Focal breathing: depth of field follows the throttle.
##      - Boost  : camera pushed back, FOV widened, distant world softens and a slight
##                 radial motion blur pulls at the screen edges.
##      - Brake  : focus snaps (a quick rack-focus hunt, then a crisp lock) onto nearby
##                 rock and passing cloud; an unsharp pulse makes the textures pop.
##  * Edge tint: a soft red (danger) or green (manta nearby) wash on the screen border
##    that fades in, holds for a couple of seconds, and melts back into the picture.
##
## Danger sources are discovered by duck-typing, so nothing here breaks if the weather
## or mission scripts are not in the scene: terrain guard, ground scrape, acid rain,
## charged clouds, lightning flashes, head-on gusts, the ground-defence grid, the sonic
## confuser, and anything in the "mentis" group.

const BASE_OFFSET := Vector3(0.0, 4.5, 15.0)
const BASE_FOV := 70.0

const MANTA_NEAR := 300.0        # green pulse when a manta comes this close
const MANTA_REARM := 520.0       # ...and again after you have left this far
const MENTIS_NEAR := 450.0

const SCREEN_SHADER := """
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float blur : hint_range(0.0, 1.0) = 0.0;
uniform float sharp : hint_range(0.0, 1.0) = 0.0;
uniform float danger : hint_range(0.0, 1.0) = 0.0;
uniform float friend : hint_range(0.0, 1.0) = 0.0;
uniform vec3 danger_col : source_color = vec3(1.0, 0.16, 0.10);
uniform vec3 friend_col : source_color = vec3(0.22, 1.0, 0.52);

void fragment() {
\tvec2 uv = SCREEN_UV;
\tvec2 d = uv - vec2(0.5);
\tfloat r = length(d) * 1.41421;

\t// Radial motion blur: samples are pulled toward the centre, stronger at the edges.
\tvec3 col;
\tif (blur > 0.002) {
\t\tfloat s = blur * 0.055 * smoothstep(0.12, 0.95, r);
\t\tvec3 acc = vec3(0.0);
\t\tfor (int i = 0; i < 8; i++) {
\t\t\tfloat f = float(i) / 7.0;
\t\t\tacc += textureLod(screen_tex, uv - d * s * f, 0.0).rgb;
\t\t}
\t\tcol = acc / 8.0;
\t} else {
\t\tcol = textureLod(screen_tex, uv, 0.0).rgb;
\t}

\t// Unsharp pulse: the focus snap onto nearby rock and cloud texture.
\tif (sharp > 0.002) {
\t\tvec3 soft = textureLod(screen_tex, uv, 1.6).rgb;
\t\tcol += (col - soft) * sharp * 1.15;
\t}

\t// Border tint: multiplicative so scene detail survives, soft inner edge.
\tfloat mask = smoothstep(0.44, 1.05, r);
\tmask *= 0.88 + 0.12 * sin(atan(d.y, d.x) * 3.0 + TIME * 0.9);
\tfloat total = danger + friend;
\tif (total > 0.002) {
\t\tvec3 tcol = (danger_col * danger + friend_col * friend) / total;
\t\tfloat a = clamp(total, 0.0, 1.0) * mask;
\t\tcol = mix(col, col * tcol * 1.15 + tcol * 0.06, a * 0.65);
\t}

\tCOLOR = vec4(col, 1.0);
}
"""


## A tint that fires, holds for a few seconds, then fades away.
class Pulse:
	var level := 0.0
	var peak := 0.0
	var hold := 0.0
	var fade := 2.0

	func fire(strength: float, hold_s: float, fade_s: float) -> void:
		peak = maxf(peak, strength) if hold > 0.0 else strength
		hold = hold_s
		fade = fade_s

	func step(dt: float) -> float:
		if hold > 0.0:
			hold -= dt
			level = move_toward(level, peak, dt / 0.25)
		else:
			peak = 0.0
			level = move_toward(level, 0.0, dt / fade)
		return level * level * (3.0 - 2.0 * level)


# Untyped on purpose: these are read through dynamic properties.
var cam: Camera3D
var plane
var flock
var guard
var terrain

var _hazards: Node
var _wind: Node
var _mission: Node
var _scan_t := 0.0

var _vel := Vector3.ZERO
var _fov := BASE_FOV
var _t := 0.0
var _attrs: CameraAttributesPractical
var _rect: ColorRect
var _mat: ShaderMaterial
var _fx_ok := false

var _boost_blur := 0.0
var _glide_focus := 0.0
var _hunt := 0.0
var _sharp := 0.0
var _ctrl_was := false

var _danger := Pulse.new()
var _friend := Pulse.new()
var _latched: Dictionary = {}
var _urgent_t := 0.0


func setup(camera: Camera3D, plane_node, flock_node, guard_node, terrain_node) -> void:
	cam = camera
	plane = plane_node
	flock = flock_node
	guard = guard_node
	terrain = terrain_node
	process_priority = 101

	_fov = cam.fov
	_snap_camera()
	_build_screen_fx()
	_build_focus()
	if plane.has_signal("scraped"):
		plane.connect("scraped", _on_scraped)


func _snap_camera() -> void:
	var fb: Basis = plane.flight_basis
	cam.global_position = plane.global_position + fb * BASE_OFFSET
	var look: Vector3 = plane.global_position + (-fb.z) * 30.0 + Vector3(0.0, 2.0, 0.0)
	cam.global_transform = Transform3D(
		Basis.looking_at(look - cam.global_position, fb.y), cam.global_position
	)


func _build_screen_fx() -> void:
	# Layer 0 sits under the HUD and mission UI (both layer 1) so they stay crisp.
	var layer := CanvasLayer.new()
	layer.name = "ScreenFX"
	layer.layer = 0
	add_child(layer)

	var shader := Shader.new()
	shader.code = SCREEN_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = shader

	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.material = _mat
	_rect.visible = false
	layer.add_child(_rect)


func _build_focus() -> void:
	# Depth of field needs Forward+ or Mobile (same as the painterly pass).
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		return
	_attrs = CameraAttributesPractical.new()
	_attrs.dof_blur_far_enabled = false
	_attrs.dof_blur_near_enabled = false
	_attrs.dof_blur_amount = 0.05
	cam.attributes = _attrs
	_fx_ok = true


func _on_scraped(_dt: float) -> void:
	_danger.fire(1.0, 1.4, 2.0)


# ---------------------------------------------------------
# Per-frame
# ---------------------------------------------------------

func _process(delta: float) -> void:
	if not is_instance_valid(plane) or not is_instance_valid(cam):
		return
	var dt: float = minf(delta, 0.05)
	_t += dt

	var boost: float = float(plane.boost_amount)
	var brake: float = float(plane.brake_amount)
	var cobra: float = float(plane.cobra_amount)
	var man: float = float(plane.maneuver_amount)
	var load_k: float = float(plane.inertia_load)
	var g: float = float(plane.g_pull)
	var roll: float = float(plane.roll)

	_follow(dt, boost, brake, cobra, man, load_k, roll)
	_cam_feel(boost, brake, cobra, man, dt, load_k, g)
	_update_focus(dt, boost, brake)
	_update_alerts(dt)
	_push_screen_fx(dt, boost)


## Spring-damper chase. The camera has mass, so it overshoots when the plane stops
## and trails behind when it surges.
func _follow(dt: float, boost: float, brake: float, cobra: float, man: float, load_k: float, roll: float) -> void:
	var fb: Basis = plane.flight_basis

	var off := BASE_OFFSET
	off.z += 7.0 * boost - 2.5 * brake + 7.0 * cobra + 5.0 * man
	off.y += 1.4 * boost - 0.8 * brake + 2.0 * cobra + 1.0 * man
	off.x = clampf(roll, -1.0, 1.0) * 1.8          # slide to the outside of a turn

	var k: float = lerpf(36.0, 26.0, boost) * lerpf(1.0, 0.82, load_k)
	var ratio: float = lerpf(0.2, 0.25, boost)       # seconds of trail behind the target
	ratio = lerpf(ratio, 0.15, brake)
	var c: float = ratio * k

	var target: Vector3 = plane.global_position + fb * off
	_vel += ((target - cam.global_position) * k - _vel * c) * dt
	cam.global_position += _vel * dt

	# Orientation also has inertia: it swings round a beat after the plane.
	var look: Vector3 = plane.global_position + (-fb.z) * 30.0 + Vector3(0.0, 2.0, 0.0)
	var dir: Vector3 = look - cam.global_position
	if dir.length() < 0.01:
		return
	var up: Vector3 = Vector3.UP.lerp(fb.y, 0.25 + 0.3 * man).normalized()
	if absf(dir.normalized().dot(up)) > 0.97:
		up = fb.y
	var want: Quaternion = Basis.looking_at(dir, up).get_rotation_quaternion()
	var have: Quaternion = cam.global_transform.basis.get_rotation_quaternion()
	var rate: float = lerpf(10.0, 6.0, load_k)
	var q: Quaternion = have.slerp(want, 1.0 - exp(-rate * dt))
	cam.global_transform = Transform3D(Basis(q), cam.global_position)


func _cam_feel(boost: float, brake: float, cobra: float, man: float, dt: float, load_k: float, g: float) -> void:
	var fov_goal: float = BASE_FOV + 12.0 * boost - 5.0 * brake + 6.0 * cobra + 3.0 * man
	_fov = lerpf(_fov, fov_goal, 1.0 - exp(-6.0 * dt))
	cam.fov = _fov

	# Engine rumble at full throttle, plus buffet in heavy air and hard pulls.
	var amp: float = 0.10 * smoothstep(0.3, 1.0, boost) + 0.05 * load_k + 0.08 * cobra + 0.04 * g
	cam.h_offset = (sin(_t * 47.0) + sin(_t * 31.0 + 1.3)) * 0.5 * amp
	cam.v_offset = (sin(_t * 53.0 + 0.7) + sin(_t * 29.0)) * 0.5 * amp


## Focal breathing: depth of field follows the throttle.
func _update_focus(dt: float, boost: float, brake: float) -> void:
	var ctrl := Input.is_key_pressed(KEY_CTRL)
	if ctrl and not _ctrl_was:
		_hunt = 1.0       # focus hunts for a beat...
		_sharp = 1.0      # ...then the texture pop lands
	_ctrl_was = ctrl
	_hunt = move_toward(_hunt, 0.0, 5.0 * dt)

	# How close is rock? Nearby mountains make the snap read stronger.
	var near_t := 0.5
	if is_instance_valid(terrain):
		var p: Vector3 = plane.global_position
		var agl: float = p.y - float(terrain.call("height_at", p.x, p.z))
		near_t = 1.0 - smoothstep(70.0, 360.0, agl)

	# Blur eases in slowly, but focus snaps back fast.
	var boost_t: float = smoothstep(0.1, 1.0, boost)
	var glide_t: float = smoothstep(0.25, 0.9, brake)
	_boost_blur = lerpf(_boost_blur, boost_t, 1.0 - exp(-(2.2 if boost_t > _boost_blur else 5.0) * dt))
	_glide_focus = lerpf(_glide_focus, glide_t, 1.0 - exp(-(12.0 if glide_t > _glide_focus else 3.0) * dt))

	var sharp_hold: float = 0.42 * (0.4 + 0.6 * near_t) * _glide_focus
	_sharp = move_toward(_sharp, sharp_hold, 1.1 * dt)

	if not _fx_ok:
		return

	# Distance (m) where far blur starts, how long it takes to reach full, and amount.
	var far_d := 900.0
	var far_tr := 1500.0
	var amt := 0.0

	far_d = lerpf(far_d, 90.0, _boost_blur)          # focus rides the aircraft
	far_tr = lerpf(far_tr, 320.0, _boost_blur)
	amt = 0.07 * _boost_blur

	far_d = lerpf(far_d, 380.0, _glide_focus)        # near rock + cloud locked, vista soft
	far_tr = lerpf(far_tr, 650.0, _glide_focus)
	amt = maxf(amt, 0.05 * _glide_focus * (0.45 + 0.55 * near_t))

	far_d *= 1.0 - 0.6 * _hunt                       # rack-focus hunt on the Ctrl press
	far_d = maxf(far_d, 70.0)                        # never blur the aircraft itself

	var on: bool = amt > 0.004 or _hunt > 0.02
	_attrs.dof_blur_far_enabled = on
	if on:
		_attrs.dof_blur_far_distance = far_d
		_attrs.dof_blur_far_transition = far_tr
		_attrs.dof_blur_amount = maxf(amt, 0.02 + 0.04 * _hunt)


# ---------------------------------------------------------
# Edge tints
# ---------------------------------------------------------

func _edge(key: String, active: bool, rearm: bool) -> bool:
	var latched: bool = _latched.get(key, false)
	if not latched and active:
		_latched[key] = true
		return true
	if latched and rearm:
		_latched[key] = false
	return false


func _discover() -> void:
	var host: Node = get_parent()
	if host == null:
		return
	for n in host.get_children():
		if _hazards == null and "in_rain" in n and "charge_proximity" in n:
			_hazards = n
		elif _wind == null and "gust_head_on" in n and "turbulence" in n:
			_wind = n
		elif _mission == null and "_defense_active" in n:
			_mission = n


func _update_alerts(dt: float) -> void:
	_scan_t -= dt
	if _scan_t <= 0.0:
		_scan_t = 1.5
		_discover()

	# --- Danger (red) ---------------------------------------------------
	var urg := 0.0
	if is_instance_valid(guard):
		urg = float(guard.get("urgency"))
	if _edge("terrain", urg > 0.55, urg < 0.3):
		_danger.fire(clampf(0.6 + urg * 0.5, 0.0, 1.0), 1.6, 2.2)
	if urg > 0.85:
		_urgent_t += dt
		if _urgent_t > 4.0:
			_urgent_t = 0.0
			_danger.fire(0.9, 1.2, 2.0)
	else:
		_urgent_t = 0.0

	if float(plane.confusion) > 0.35:
		if _edge("confuser", true, false):
			_danger.fire(0.8, 1.8, 2.4)
	else:
		_edge("confuser", false, true)

	if is_instance_valid(_hazards):
		var rain: bool = bool(_hazards.get("in_rain"))
		if _edge("rain", rain, not rain):
			_danger.fire(0.6, 1.6, 2.4)
		var charge: float = float(_hazards.get("charge_proximity"))
		if _edge("charge", charge > 0.55, charge < 0.25):
			_danger.fire(0.75, 1.8, 2.4)
		if float(_hazards.get("flash")) > 0.7:
			_danger.fire(0.85, 0.8, 1.6)

	if is_instance_valid(_wind):
		var gust: float = float(_wind.get("gust"))
		var head_on: bool = bool(_wind.get("gust_head_on"))
		if _edge("gust", gust > 0.8 and head_on, gust < 0.3):
			_danger.fire(0.4, 1.2, 2.0)

	if is_instance_valid(_mission):
		var grid: bool = bool(_mission.get("_defense_active"))
		if _edge("grid", grid, not grid):
			_danger.fire(0.8, 2.0, 2.4)

	var hunter_near := false
	for n in get_tree().get_nodes_in_group("mentis"):
		if n is Node3D and (n as Node3D).global_position.distance_to(plane.global_position) < MENTIS_NEAR:
			hunter_near = true
			break
	if _edge("mentis", hunter_near, not hunter_near):
		_danger.fire(1.0, 2.4, 2.6)

	# --- Manta nearby (green) ---------------------------------------------
	if is_instance_valid(flock):
		var near: Dictionary = flock.nearest(plane.global_position)
		var dist: float = float(near.get("dist", 99999.0))
		if _edge("manta", dist < MANTA_NEAR, dist > MANTA_REARM):
			_friend.fire(0.85, 1.6, 2.8)


func _push_screen_fx(dt: float, boost: float) -> void:
	var d: float = _danger.step(dt)
	var f: float = _friend.step(dt)
	var blur: float = _boost_blur * _boost_blur * 0.8

	_rect.visible = blur > 0.004 or _sharp > 0.004 or d > 0.004 or f > 0.004
	if not _rect.visible:
		return
	_mat.set_shader_parameter("blur", blur)
	_mat.set_shader_parameter("sharp", _sharp)
	_mat.set_shader_parameter("danger", d * 0.9)
	_mat.set_shader_parameter("friend", f * 0.15)
