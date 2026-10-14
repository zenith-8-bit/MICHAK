extends Node3D
## Arcade flight model for the Blender plane. Nose points to -Z (Godot forward).
##  W / Up = dive    S / Down = climb    A / Left, D / Right = bank & turn
##  Shift = boost    Ctrl = brake

var terrain: Node3D
var speed := 75.0
var pitch := 0.0
var yaw := 0.0
var roll := 0.0

const CRUISE := 75.0
const BOOST := 135.0
const BRAKE := 45.0


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
