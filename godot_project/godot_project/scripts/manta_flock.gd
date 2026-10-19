extends Node3D
## Giant sky-mantas gliding over the canyon. Each one wanders on a slow noisy heading,
## keeps a target height above the ground, and respawns ahead of the player when left behind.
##
## Wanderers drift toward the nesting grounds (the "dwelling") over time, so following
## the herd leads you to it. A few residents live at the dwelling permanently.
## Wherever they settle the ground seeps fuel: a golden vapor column marks the spot.

const RESIDENTS := 3

var _scene: PackedScene
var _terrain: Node3D
var _player: Node3D
var _mantas: Array[Dictionary] = []
var _time := 0.0

var dwelling_pos := Vector3.ZERO
var has_dwelling := false
var _marker: Node3D


func setup(manta_scene: PackedScene, terrain: Node3D, player: Node3D, count: int = 7) -> void:
	_scene = manta_scene
	_terrain = terrain
	_player = player
	for i in count:
		var d := _create()
		d["resident"] = false
		_place(d, i == 0)
		_mantas.append(d)


## Declares where the herd nests. The last few mantas become permanent residents.
func set_dwelling(pos: Vector3) -> void:
	dwelling_pos = pos
	has_dwelling = true
	var n := _mantas.size()
	for i in range(maxi(n - RESIDENTS, 1), n):
		var d: Dictionary = _mantas[i]
		d["resident"] = true
		var ang := randf() * TAU
		var p := pos + Vector3(cos(ang), 0.0, sin(ang)) * randf_range(120.0, 320.0)
		d["alt"] = randf_range(70.0, 150.0)
		p.y = _terrain.height_at(p.x, p.z) + float(d["alt"])
		d["pos"] = p
		d["heading"] = randf() * TAU
	_build_marker()


func _build_marker() -> void:
	_marker = Node3D.new()
	_marker.name = "FuelVapor"
	_marker.position = dwelling_pos
	add_child(_marker)

	var vapor := CPUParticles3D.new()
	vapor.amount = 60
	vapor.lifetime = 5.0
	vapor.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	vapor.emission_sphere_radius = 90.0
	vapor.direction = Vector3.UP
	vapor.spread = 8.0
	vapor.gravity = Vector3.ZERO
	vapor.initial_velocity_min = 14.0
	vapor.initial_velocity_max = 26.0
	vapor.scale_amount_min = 6.0
	vapor.scale_amount_max = 14.0
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 0.72, 0.30, 1.0)
	mat.render_priority = 110
	quad.material = mat
	vapor.mesh = quad
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0),
		Color(1.0, 1.0, 1.0, 0.22),
		Color(1.0, 1.0, 1.0, 0.0),
	])
	vapor.color_ramp = ramp
	_marker.add_child(vapor)

	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.70, 0.30)
	glow.light_energy = 3.0
	glow.omni_range = 220.0
	glow.position = Vector3(0.0, 40.0, 0.0)
	_marker.add_child(glow)


## Closest manta to a point: {"dist": float, "pos": Vector3}.
func nearest(from: Vector3) -> Dictionary:
	var best := 99999.0
	var best_pos := Vector3.ZERO
	for d in _mantas:
		var p: Vector3 = d["pos"]
		var dist := from.distance_to(p)
		if dist < best:
			best = dist
			best_pos = p
	return {"dist": best, "pos": best_pos}


func _create() -> Dictionary:
	var node := Node3D.new()
	var inst: Node = _scene.instantiate()
	node.add_child(inst)
	add_child(node)
	var players := inst.find_children("*", "AnimationPlayer", true, false)
	if players.size() > 0:
		var ap := players[0] as AnimationPlayer
		for a in ap.get_animation_list():
			if a != "RESET":
				ap.get_animation(a).loop_mode = Animation.LOOP_LINEAR
				ap.speed_scale = randf_range(0.55, 1.0)
				ap.play(a)
				break
	return {
		"node": node,
		"pos": Vector3.ZERO,
		"heading": 0.0,
		"speed": randf_range(18.0, 30.0),
		"scale": randf_range(1.8, 3.2),
		"alt": randf_range(110.0, 260.0),
		"phase": randf() * TAU,
		"freq": randf_range(0.05, 0.12),
		"pitch": 0.0,
		"resident": false,
	}


func _place(d: Dictionary, hero: bool) -> void:
	var fwd := -_player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP)
	var pos: Vector3
	if hero:
		# one big manta sweeping across the player's view at the start
		pos = _player.position + fwd * 260.0 + right * 70.0
		d["scale"] = 3.6
		d["heading"] = atan2(-fwd.x, -fwd.z) + 0.25
		d["alt"] = 170.0
	else:
		var ang := randf_range(-1.1, 1.1) if _mantas.size() > 0 else randf() * TAU
		var dir := fwd.rotated(Vector3.UP, ang)
		pos = _player.position + dir * randf_range(280.0, 950.0)
		d["heading"] = randf() * TAU
	pos.y = _terrain.height_at(pos.x, pos.z) + d["alt"]
	d["pos"] = pos


func _process(delta: float) -> void:
	_time += delta
	if _marker != null:
		_marker.visible = _player.global_position.distance_to(dwelling_pos) < 2200.0

	for d in _mantas:
		var turn := sin(_time * d["freq"] + d["phase"])
		d["heading"] += turn * 0.12 * delta
		var p: Vector3 = d["pos"]

		# Drift toward the nesting grounds, then circle there.
		if has_dwelling:
			var to_home := dwelling_pos - p
			to_home.y = 0.0
			if to_home.length() > 380.0:
				var want_h := atan2(-to_home.x, -to_home.z)
				d["heading"] = lerp_angle(d["heading"], want_h, 1.0 - exp(-0.35 * delta))
			else:
				d["heading"] += 0.22 * delta

		var want: float = _terrain.height_at(p.x, p.z) + d["alt"]
		d["pitch"] = lerpf(d["pitch"], clampf((want - p.y) * 0.004, -0.3, 0.3), 1.0 - exp(-1.5 * delta))
		var bank := -turn * 0.35
		var b := Basis.from_euler(Vector3(d["pitch"], d["heading"], bank), EULER_ORDER_YXZ)
		p += -b.z * d["speed"] * delta
		d["pos"] = p
		var node: Node3D = d["node"]
		node.transform = Transform3D(b.scaled(Vector3.ONE * d["scale"]), p)
		if not d["resident"] and p.distance_to(_player.position) > 1300.0:
			_place(d, false)