extends Node3D
## Weather hazards: acid-rain cells that corrode the hull, and negatively
## charged storm clouds that throw lightning and scramble every sensor.

class Storm:
	var pos := Vector3.ZERO
	var radius := 300.0
	var node: MeshInstance3D

class Charge:
	var pos := Vector3.ZERO
	var radius := 150.0
	var node: Node3D
	var mat: StandardMaterial3D
	var strike_t := 3.0
	var phase := 0.0

const BOLT_PRIORITY := 110

var plane: Node3D
var terrain: Node3D
var mission: Node
var audio: Node

var rain_amount := 0.0
var in_rain := false
var scramble := 0.0              # 0..1 sensor interference
var charge_proximity := 0.0
var flash := 0.0                 # 0..1 white lightning flash (HUD overlay)

var _spike := 0.0
var _storms: Array[Storm] = []
var _clouds: Array[Charge] = []
var _rain: CPUParticles3D
var _bolt_mat: StandardMaterial3D
var _t := 0.0


func setup(terrain_node: Node3D, plane_node: Node3D, mission_node: Node, audio_node: Node) -> void:
	terrain = terrain_node
	plane = plane_node
	mission = mission_node
	audio = audio_node

	_bolt_mat = StandardMaterial3D.new()
	_bolt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bolt_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bolt_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_bolt_mat.albedo_color = Color(0.85, 0.80, 1.0, 1.0)
	_bolt_mat.render_priority = BOLT_PRIORITY

	_build_rain()

	var fwd: Vector3 = -plane.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right: Vector3 = fwd.cross(Vector3.UP)

	for i in range(3):
		var s := Storm.new()
		s.radius = randf_range(260.0, 420.0)
		if i == 0:
			s.pos = plane.global_position + fwd * 1200.0 + right * 420.0
		else:
			s.pos = _far_point(1400.0, 2400.0)
		_make_storm(s)
		_storms.append(s)

	for i in range(4):
		var c := Charge.new()
		c.radius = randf_range(110.0, 180.0)
		c.phase = randf() * TAU
		c.strike_t = randf_range(2.0, 5.0)
		if i == 0:
			c.pos = plane.global_position + fwd * 1000.0 - right * 380.0
			c.pos.y = 230.0
		else:
			c.pos = _far_point(1200.0, 2400.0)
			c.pos.y = randf_range(170.0, 320.0)
		_make_cloud(c)
		_clouds.append(c)


func _far_point(dmin: float, dmax: float) -> Vector3:
	var fwd: Vector3 = -plane.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var dir: Vector3 = fwd.rotated(Vector3.UP, randf_range(-1.3, 1.3))
	return plane.global_position + dir * randf_range(dmin, dmax)


func _build_rain() -> void:
	_rain = CPUParticles3D.new()
	_rain.top_level = true
	_rain.emitting = false
	_rain.amount = 700
	_rain.lifetime = 0.7
	_rain.local_coords = false
	_rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_rain.emission_box_extents = Vector3(70.0, 4.0, 70.0)
	_rain.direction = Vector3(0.1, -1.0, 0.05)
	_rain.spread = 2.0
	_rain.gravity = Vector3(0.0, -30.0, 0.0)
	_rain.initial_velocity_min = 80.0
	_rain.initial_velocity_max = 100.0
	_rain.particle_flag_align_y = true
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.04, 1.6, 0.04)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.82, 0.78, 0.95, 0.55)
	mat.render_priority = BOLT_PRIORITY
	mesh.material = mat
	_rain.mesh = mesh
	add_child(_rain)


func _make_storm(s: Storm) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = s.radius
	mesh.bottom_radius = s.radius * 1.05
	mesh.height = 480.0
	mesh.radial_segments = 32
	mesh.rings = 1
	mesh.cap_top = true
	mesh.cap_bottom = false
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.26, 0.17, 0.33, 0.30)
	mat.disable_fog = true
	mesh.material = mat
	s.node = MeshInstance3D.new()
	s.node.mesh = mesh
	s.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.node.position = Vector3(s.pos.x, 200.0, s.pos.z)
	add_child(s.node)


func _make_cloud(c: Charge) -> void:
	c.mat = StandardMaterial3D.new()
	c.mat.albedo_color = Color(0.22, 0.12, 0.30, 0.9)
	c.mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	c.mat.roughness = 1.0
	c.mat.emission_enabled = true
	c.mat.emission = Color(0.55, 0.25, 0.85)
	c.mat.emission_energy_multiplier = 0.25

	c.node = Node3D.new()
	for i in range(7):
		var m := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 16
		sphere.rings = 8
		m.mesh = sphere
		m.material_override = c.mat
		var r: float = c.radius * randf_range(0.35, 0.65)
		m.scale = Vector3(r, r * 0.62, r)
		m.position = Vector3(randf_range(-1.0, 1.0), randf_range(-0.25, 0.35), randf_range(-1.0, 1.0)) * c.radius * 0.6
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		c.node.add_child(m)
	var light := OmniLight3D.new()
	light.light_color = Color(0.70, 0.45, 1.0)
	light.light_energy = 0.4
	light.omni_range = c.radius * 2.0
	c.node.add_child(light)
	c.node.position = c.pos
	add_child(c.node)


func _process(delta: float) -> void:
	if not is_instance_valid(plane):
		return
	_t += delta
	var p: Vector3 = plane.global_position

	# --- Acid rain -------------------------------------------------
	rain_amount = 0.0
	for s in _storms:
		s.pos += Vector3(4.0, 0.0, 1.5) * delta
		s.node.position = Vector3(s.pos.x, 200.0, s.pos.z)
		var hd: float = Vector2(p.x - s.pos.x, p.z - s.pos.z).length()
		if hd > 2800.0:
			s.pos = _far_point(1500.0, 2300.0)
		var inside: float = 1.0 - smoothstep(s.radius * 0.72, s.radius, hd)
		var below_roof: float = 1.0 - smoothstep(380.0, 430.0, p.y)
		rain_amount = maxf(rain_amount, inside * below_roof)
	in_rain = rain_amount > 0.05
	if in_rain and is_instance_valid(mission):
		mission.call("drain", 1.8 * rain_amount * delta)
	_rain.global_position = p + Vector3(0.0, 35.0, 0.0)
	_rain.emitting = in_rain

	# --- Charged clouds -------------------------------------------
	var target: float = 0.0
	for c in _clouds:
		c.pos += Vector3(-2.0, 0.0, 1.0) * delta
		c.node.position = c.pos
		var d: float = p.distance_to(c.pos)
		if d > 2800.0:
			c.pos = _far_point(1400.0, 2300.0)
			c.pos.y = randf_range(170.0, 320.0)
		target = maxf(target, 1.0 - smoothstep(c.radius * 0.8, c.radius * 2.4, d))
		c.mat.emission_energy_multiplier = 0.25 + 0.2 * sin(_t * 3.0 + c.phase) + flash * 1.5
		c.strike_t -= delta
		if c.strike_t <= 0.0 and d < 1100.0:
			c.strike_t = randf_range(1.6, 4.2)
			_strike(c, p, d)
	charge_proximity = target
	target = maxf(target, _spike)
	_spike = maxf(_spike - 0.3 * delta, 0.0)
	scramble = lerpf(scramble, target, 1.0 - exp(-3.0 * delta))
	flash = maxf(flash - 3.5 * delta, 0.0)


func _strike(c: Charge, p: Vector3, d: float) -> void:
	var hit_player: bool = d < c.radius * 1.3 and randf() < 0.45
	var from: Vector3 = c.pos + Vector3(randf_range(-1.0, 1.0), -c.radius * 0.2, randf_range(-1.0, 1.0)) * c.radius * 0.3
	var to: Vector3
	if hit_player:
		to = p + Vector3(randf_range(-4.0, 4.0), 1.0, randf_range(-4.0, 4.0))
	else:
		var gx: float = c.pos.x + randf_range(-1.0, 1.0) * c.radius * 1.2
		var gz: float = c.pos.z + randf_range(-1.0, 1.0) * c.radius * 1.2
		to = Vector3(gx, float(terrain.call("height_at", gx, gz)), gz)
	_spawn_bolt(from, to)
	flash = maxf(flash, clampf(1.1 - d / 1400.0, 0.1, 1.0))

	var delay: float = clampf(d / 800.0, 0.05, 2.0)
	var vol: float = -4.0 - clampf(d / 150.0, 0.0, 22.0)
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		if is_instance_valid(audio):
			audio.call("play_sfx", "thunder", vol, randf_range(0.85, 1.1))
	)

	if hit_player:
		_spike = 1.0
		if is_instance_valid(mission):
			mission.call("damage", 10.0, "lightning strike")


func _spawn_bolt(from: Vector3, to: Vector3) -> void:
	var segs: int = 11
	var pts: Array[Vector3] = []
	for i in range(segs + 1):
		var u: float = float(i) / float(segs)
		var pnt: Vector3 = from.lerp(to, u)
		if i > 0 and i < segs:
			pnt += Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * 16.0 * (1.0 - absf(u - 0.5) * 1.2)
		pts.append(pnt)

	var im := ImmediateMesh.new()
	for layer in range(3):
		var off := Vector3(0.9 * float(layer), 0.0, 0.9 * float(layer))
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for pnt in pts:
			im.surface_add_vertex(pnt + off)
		im.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = _bolt_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 4096.0
	add_child(mi)
	get_tree().create_timer(0.22).timeout.connect(mi.queue_free)
