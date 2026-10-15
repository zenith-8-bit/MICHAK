extends Node3D
## Arcade flight model for the Blender plane. Nose points to -Z (Godot forward).
##  W / Up = dive    S / Down = climb    A / Left, D / Right = bank & turn
##  Shift = boost (also fires the sonic-boom VFX)    Ctrl = brake

var terrain: Node3D
var speed := 75.0
var pitch := 0.0
var yaw := 0.0
var roll := 0.0

## 0..1, how far into boost the plane is (follows the real speed, so it ramps
## up and fades out smoothly). main.gd reads it for a small FOV kick.
var boost_amount := 0.0

const CRUISE := 75.0
const BOOST := 135.0
const BRAKE := 45.0

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

var _cone: MeshInstance3D
var _cone_mat: ShaderMaterial
var _streaks: CPUParticles3D
var _ring_shader: Shader
var _shift_was_down := false
var _boom_cooldown := 0.0
var _trickle := 0.0


func _ready() -> void:
	_ring_shader = Shader.new()
	_ring_shader.code = RING_SHADER
	_build_cone()
	_build_streaks()


func setup(scene: PackedScene) -> void:
	add_child(scene.instantiate())


func _axis(neg: Array, pos: Array) -> float:
	var v := 0.0
	for k in pos:
		if Input.is_key_pressed(k):
			v += 1.0
	for k in neg:
		if Input.is_key_pressed(k):
			v -= 1.0
	return clampf(v, -1.0, 1.0)


func _process(delta: float) -> void:
	var pitch_in := _axis([KEY_W, KEY_UP], [KEY_S, KEY_DOWN])
	var roll_in := _axis([KEY_D, KEY_RIGHT], [KEY_A, KEY_LEFT])

	pitch += pitch_in * 0.9 * delta
	if is_zero_approx(pitch_in):
		pitch = lerpf(pitch, 0.0, 1.0 - exp(-0.8 * delta))
	pitch = clampf(pitch, -0.9, 0.9)

	roll = lerpf(roll, roll_in * 0.95, 1.0 - exp(-4.0 * delta))
	yaw += sin(roll) * 0.9 * delta

	var target := CRUISE
	if Input.is_key_pressed(KEY_SHIFT):
		target = BOOST
	elif Input.is_key_pressed(KEY_CTRL):
		target = BRAKE
	speed = lerpf(speed, target, 1.0 - exp(-2.0 * delta))

	basis = Basis.from_euler(Vector3(pitch, yaw, roll), EULER_ORDER_YXZ)
	position += -basis.z * speed * delta

	if terrain:
		var ground: float = terrain.height_at(position.x, position.z) + 12.0
		if position.y < ground:
			position.y = ground
			pitch = maxf(pitch, 0.12)
	position.y = minf(position.y, 900.0)

	_update_boost_vfx(delta)


# ---------------------------------------------------------
# Boost VFX: shock cone + pressure rings + rushing air streaks
# ---------------------------------------------------------

func _update_boost_vfx(delta: float) -> void:
	boost_amount = clampf((speed - CRUISE) / (BOOST - CRUISE), 0.0, 1.0)

	# Every fresh Shift press fires the boom.
	var shift_down := Input.is_key_pressed(KEY_SHIFT)
	_boom_cooldown = maxf(_boom_cooldown - delta, 0.0)
	if shift_down and not _shift_was_down and _boom_cooldown <= 0.0:
		_fire_boom()
		_boom_cooldown = BOOM_COOLDOWN
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


## One expanding shockwave ring. It is left behind in world space (top_level)
## while the plane flies on, so it reads as air being torn open.
func _spawn_ring(radius: float, duration: float, strength: float, delay: float = 0.0) -> void:
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
	mat.set_shader_parameter("fade", strength)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	add_child(mi)

	# Perpendicular to the flight direction, at the nose.
	mi.global_transform = Transform3D(global_transform.basis.orthonormalized(), to_global(NOSE_OFFSET))
	mi.scale = Vector3.ONE * 0.5

	var tw := mi.create_tween().set_parallel(true)
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