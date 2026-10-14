extends Node3D
## Giant sky-mantas gliding over the canyon. Each one wanders on a slow noisy heading,
## keeps a target height above the ground, and respawns ahead of the player when left behind.

var _scene: PackedScene
var _terrain: Node3D
var _player: Node3D
var _mantas: Array[Dictionary] = []
var _time := 0.0


func setup(manta_scene: PackedScene, terrain: Node3D, player: Node3D, count: int = 7) -> void:
	_scene = manta_scene
	_terrain = terrain
	_player = player
	for i in count:
		var d := _create()
		_place(d, i == 0)
		_mantas.append(d)


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
	for d in _mantas:
		var turn := sin(_time * d["freq"] + d["phase"])
		d["heading"] += turn * 0.12 * delta
		var p: Vector3 = d["pos"]
		var want: float = _terrain.height_at(p.x, p.z) + d["alt"]
		d["pitch"] = lerpf(d["pitch"], clampf((want - p.y) * 0.004, -0.3, 0.3), 1.0 - exp(-1.5 * delta))
		var bank := -turn * 0.35
		var b := Basis.from_euler(Vector3(d["pitch"], d["heading"], bank), EULER_ORDER_YXZ)
		p += -b.z * d["speed"] * delta
		d["pos"] = p
		var node: Node3D = d["node"]
		node.transform = Transform3D(b.scaled(Vector3.ONE * d["scale"]), p)
		if p.distance_to(_player.position) > 1300.0:
			_place(d, false)
