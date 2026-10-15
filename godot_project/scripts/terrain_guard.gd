extends Node
## Terrain guard: keeps the aircraft well above the ground.
##
## 1. Hard floor      - never closer than min_clearance to the ground
##                      under the fuselage or wing tips.
## 2. Look-ahead      - samples terrain along the flight path; if the
##                      current heading would bring the plane inside
##                      comfort_clearance, it applies an evasive climb
##                      sized to the time left before impact.
## 3. Pitch assist    - noses the plane up while evading.
##
## Runs after the plane (priority 0) and before the camera (priority 100).

@export var min_clearance: float = 120.0       # hard floor above ground (m)
@export var comfort_clearance: float = 210.0   # evasion starts below this (m)
@export var lookahead_seconds: float = 3.0
@export var max_climb_rate: float = 170.0      # strongest upward push (m/s)
@export var response: float = 4.0              # how fast the push ramps
@export var pitch_assist_deg: float = 40.0     # nose-up assist (deg/s)
@export var wing_half_span: float = 45.0       # lateral sample offset (m)

## 0..1, how hard the guard is working. Use it for HUD warnings.
var urgency: float = 0.0

var plane: Node3D
var terrain: Node3D
var _climb: float = 0.0

const _SIDES := [-1.0, 0.0, 1.0]
const _FRACS := [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]


func setup(plane_node: Node3D, terrain_node: Node3D) -> void:
	plane = plane_node
	terrain = terrain_node
	process_priority = 50


func _ground(x: float, z: float) -> float:
	return float(terrain.call("height_at", x, z))


func _process(delta: float) -> void:
	if not is_instance_valid(plane) or not is_instance_valid(terrain):
		return

	var pos: Vector3 = plane.global_position
	var fwd: Vector3 = -plane.global_transform.basis.z
	var speed: float = maxf(float(plane.get("speed")), 40.0)

	var hdir := Vector3(fwd.x, 0.0, fwd.z)
	if hdir.length() < 0.01:
		hdir = Vector3(0.0, 0.0, -1.0)
	hdir = hdir.normalized()
	var right: Vector3 = hdir.cross(Vector3.UP)

	var look: float = speed * lookahead_seconds
	var need_rate: float = 0.0
	var ground_here: float = -INF

	for f in _FRACS:
		var d: float = look * float(f)
		var projected_y: float = pos.y + fwd.y * d

		for s in _SIDES:
			var q: Vector3 = pos + hdir * d + right * float(s) * wing_half_span
			var g: float = _ground(q.x, q.z)

			if d == 0.0:
				ground_here = maxf(ground_here, g)

			# Would the current heading end up inside the comfort band?
			var deficit: float = (g + comfort_clearance) - projected_y
			if deficit > 0.0:
				need_rate = maxf(need_rate, deficit * speed / maxf(d, 60.0))

	# How close we are right now, 0 (comfortable) .. 1 (at the floor).
	var clearance: float = pos.y - ground_here
	var u_now: float = 1.0 - clampf(
		(clearance - min_clearance) / (comfort_clearance - min_clearance),
		0.0,
		1.0
	)
	var u_ahead: float = clampf(need_rate / max_climb_rate, 0.0, 1.0)

	var target_urgency: float = maxf(u_now, u_ahead)
	urgency = lerpf(urgency, target_urgency, 1.0 - exp(-6.0 * delta))

	# Evasive climb: sized to what the look-ahead needs, with a floor
	# from how close we already are.
	var target_climb: float = maxf(
		clampf(need_rate * 1.15, 0.0, max_climb_rate),
		u_now * max_climb_rate * 0.6
	)
	_climb = lerpf(_climb, target_climb, 1.0 - exp(-response * delta))
	pos.y += _climb * delta

	# Hard floor: smooth, with a direct clamp as the last resort.
	var floor_y: float = ground_here + min_clearance
	if pos.y < floor_y:
		pos.y = lerpf(pos.y, floor_y, 1.0 - exp(-10.0 * delta))
		pos.y = maxf(pos.y, ground_here + min_clearance * 0.7)

	plane.global_position = pos

	# Nose-up assist while evading (stops at a ~27 degree climb).
	if urgency > 0.05 and fwd.y < 0.45:
		plane.rotate_object_local(
			Vector3.RIGHT,
			deg_to_rad(pitch_assist_deg) * urgency * delta
		)
