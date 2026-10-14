extends Node3D
## Canyon Skies - wires everything together.

const TerrainScript := preload("res://scripts/terrain_generator.gd")
const PlaneScript := preload("res://scripts/plane_controller.gd")
const FlockScript := preload("res://scripts/manta_flock.gd")
const CloudScript := preload("res://scripts/cloud_field.gd")

var terrain: Node3D
var plane: Node3D
var cam: Camera3D
var hud: Label


func _ready() -> void:
	process_priority = 100  # run after the plane so the camera never lags a frame
	_make_environment()

	terrain = TerrainScript.new()
	add_child(terrain)
	terrain.prewarm(Vector3.ZERO, 2)

	plane = PlaneScript.new()
	plane.terrain = terrain
	add_child(plane)
	plane.setup(load("res://assets/models/plane.glb"))
	plane.position = Vector3(0, 340, 0)

	var flock := FlockScript.new()
	add_child(flock)
	flock.setup(load("res://assets/models/manta.glb"), terrain, plane, 7)

	var clouds := CloudScript.new()
	add_child(clouds)
	clouds.setup(plane, 45)

	cam = Camera3D.new()
	cam.fov = 70.0
	cam.far = 4000.0
	add_child(cam)
	cam.global_position = plane.global_transform * Vector3(0, 4.5, 15)

	var layer := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_color_override("font_color", Color(1, 0.93, 0.85))
	hud.add_theme_color_override("font_shadow_color", Color(0.25, 0.1, 0.15, 0.8))
	hud.add_theme_constant_override("shadow_offset_x", 2)
	hud.add_theme_constant_override("shadow_offset_y", 2)
	layer.add_child(hud)
	add_child(layer)


func _make_environment() -> void:
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color(0.36, 0.38, 0.66)
	psm.sky_horizon_color = Color(0.98, 0.72, 0.56)
	psm.ground_horizon_color = Color(0.95, 0.66, 0.52)
	psm.ground_bottom_color = Color(0.60, 0.40, 0.45)
	psm.sun_angle_max = 25.0
	psm.sun_curve = 0.15
	var sky := Sky.new()
	sky.sky_material = psm

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.04
	env.fog_enabled = true
	env.fog_light_color = Color(0.93, 0.66, 0.55)
	env.fog_density = 0.0019
	env.fog_sky_affect = 0.5
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.1
	env.adjustment_contrast = 1.05

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-32, -55, 0)
	sun.light_color = Color(1.0, 0.84, 0.68)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 900.0
	add_child(sun)


func _process(delta: float) -> void:
	if Input.is_key_pressed(KEY_ESCAPE):
		get_tree().quit()
	terrain.update_chunks(plane.position)

	var target: Vector3 = plane.global_transform * Vector3(0, 4.5, 15)
	cam.global_position = cam.global_position.lerp(target, 1.0 - exp(-5.0 * delta))
	var fwd: Vector3 = -plane.global_transform.basis.z
	var up := Vector3.UP.lerp(plane.global_transform.basis.y, 0.25).normalized()
	cam.look_at(plane.global_position + fwd * 30.0 + Vector3(0, 2, 0), up)

	hud.text = "W/S pitch   A/D bank   Shift boost   Ctrl brake   Esc quit\nALT %d m    SPD %d m/s" % [plane.position.y, plane.speed]
