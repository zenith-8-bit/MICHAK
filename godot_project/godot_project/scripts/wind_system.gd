extends Node
## Harsh wind: a steady ambient flow, random gusts (often head-on) and heavy
## turbulence near the ground and beside ridges. Rewrites the plane's wind_push
## and wind_torque every frame and drives the rushing-air streak particles.

signal gust_started(head_on: bool)

const GUST_MAX_SPEED := 38.0
const VFX_PRIORITY := 110

var plane: Node3D
var terrain: Node3D
var cam: Camera3D

var wind_vec := Vector3.ZERO        # world-space wind velocity (m/s)
var wind_speed := 0.0
var gust := 0.0                     # 0..1 current gust strength
var gust_head_on := false
var headwind := 0.0                 # m/s of wind blowing against the heading
var turbulence := 0.0               # 0..1, ground / ridge proximity
var ridge_near := 0.0
var agl := 999.0

var _t := 0.0
var _gust_dir := Vector3.ZERO
var _gust_peak := 0.0
var _gust_len := 3.0
var _gust_age := 99.0
var _gust_timer := 9.0
var _noise := FastNoiseLite.new()
var _streaks: CPUParticles3D


func setup(plane_node: Node3D, terrain_node: Node3D, camera: Camera3D) -> void:
	plane = plane_node
	terrain = terrain_node
	cam = camera
	process_priority = 20
	_noise.seed = 913
	_noise.frequency = 1.0
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_build_streaks()


func _build_streaks() -> void:
	_streaks = CPUParticles3D.new()
	_streaks.emitting = false
	_streaks.amount = 90
	_streaks.lifetime = 0.4
	_streaks.local_coords = true
	_streaks.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_streaks.emission_box_extents = Vector3(16.0, 9.0, 4.0)
	_streaks.direction = Vector3(0.0, 0.0, 1.0)
	_streaks.spread = 3.0
	_streaks.gravity = Vector3.ZERO
	_streaks.initial_velocity_min = 90.0
	_streaks.initial_velocity_max = 150.0
	_streaks.particle_flag_align_y = true

	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.05, 3.5, 0.05)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 0.92, 0.82, 1.0)
	mat.render_priority = VFX_PRIORITY
	mesh.material = mat
	_streaks.mesh = mesh

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0),
		Color(1.0, 1.0, 1.0, 0.7),
		Color(1.0, 1.0, 1.0, 0.0),
	])
	_streaks.color_ramp = ramp
	_streaks.position = Vector3(0.0, 0.0, -22.0)
	cam.add_child(_streaks)


func _process(delta: float) -> void:
	if not is_instance_valid(plane) or not is_instance_valid(terrain):
		return
	_t += delta

	var pos: Vector3 = plane.global_position
	var ground: float = float(terrain.call("height_at", pos.x, pos.z))
	agl = pos.y - ground

	var fwd_h: Vector3 = -plane.global_transform.basis.z
	fwd_h.y = 0.0
	if fwd_h.length() < 0.01:
		fwd_h = Vector3(0.0, 0.0, -1.0)
	fwd_h = fwd_h.normalized()
	var right: Vector3 = fwd_h.cross(Vector3.UP)

	# Terrain level with our altitude to either side or ahead = ridge turbulence.
	var ridge: float = 0.0
	for off in [right * 70.0, right * -70.0, fwd_h * 140.0]:
		var o: Vector3 = off
		var g: float = float(terrain.call("height_at", pos.x + o.x, pos.z + o.z))
		ridge = maxf(ridge, 1.0 - smoothstep(-5.0, 90.0, pos.y - g))
	ridge_near = lerpf(ridge_near, ridge, 1.0 - exp(-4.0 * delta))
	var low: float = 1.0 - smoothstep(30.0, 170.0, agl)
	turbulence = clampf(maxf(low, ridge_near * 0.9), 0.0, 1.0)

	# Gusts.
	_gust_timer -= delta
	_gust_age += delta
	if _gust_timer <= 0.0:
		_start_gust(fwd_h, right)
		_gust_timer = randf_range(7.0, 15.0)
	var env: float = 0.0
	if _gust_age < _gust_len:
		env = pow(sin(clampf(_gust_age / _gust_len, 0.0, 1.0) * PI), 0.8)
	gust = env * _gust_peak

	# Total wind.
	var amb: Vector3 = Vector3(1.0, 0.0, 0.35).normalized().rotated(Vector3.UP, sin(_t * 0.05) * 0.8)
	var amb_speed: float = 7.0 + 4.0 * _noise.get_noise_2d(_t * 0.15, 3.0) + turbulence * 6.0
	wind_vec = amb * amb_speed + _gust_dir * gust * GUST_MAX_SPEED
	wind_vec.y = _noise.get_noise_2d(_t * 0.9, 11.0) * turbulence * 16.0 - turbulence * 3.0
	wind_speed = wind_vec.length()
	headwind = maxf(-wind_vec.dot(fwd_h), 0.0)

	plane.set("wind_push", wind_vec * 0.5)
	var tq: float = turbulence * turbulence + gust * 0.35
	plane.set("wind_torque", Vector3(
		_noise.get_noise_2d(_t * 2.1, 21.0) * 0.55,
		_noise.get_noise_2d(_t * 1.3, 37.0) * 0.30,
		_noise.get_noise_2d(_t * 2.7, 53.0) * 1.15
	) * tq)

	# Air streaks flow along (wind - plane velocity), seen from the camera.
	if is_instance_valid(cam):
		var vel: Vector3 = -plane.global_transform.basis.z * float(plane.get("speed"))
		var rel: Vector3 = wind_vec - vel
		var local_dir: Vector3 = cam.global_transform.basis.inverse() * rel.normalized()
		_streaks.direction = local_dir
		_streaks.emitting = gust > 0.12 or turbulence > 0.45
		_streaks.speed_scale = lerpf(0.8, 1.7, clampf(gust + turbulence * 0.6, 0.0, 1.0))


func _start_gust(fwd_h: Vector3, right: Vector3) -> void:
	gust_head_on = randf() < 0.55
	if gust_head_on:
		_gust_dir = (-fwd_h + right * randf_range(-0.25, 0.25)).normalized()
	else:
		var side: float = 1.0 if randf() < 0.5 else -1.0
		_gust_dir = (right * side + fwd_h * randf_range(-0.3, 0.3)).normalized()
	_gust_peak = randf_range(0.55, 1.0)
	_gust_len = randf_range(2.6, 5.0)
	_gust_age = 0.0
	gust_started.emit(gust_head_on)
