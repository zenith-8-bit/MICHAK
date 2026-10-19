extends Node3D
## Canyon Skies — procedural volumetric cloud field for Godot 4.x.
## Pair this script with canyon_clouds.gdshader in the same project folder.
## Call setup(player) once the aircraft/player node exists.

const VOLUME_SHADER: Shader = preload("res://clouds_field.gdshader")
const DISTANT_SKY_SHADER: Shader = preload("res://shaders/canyon_clouds.gdshader")

const CLOUD_TYPES: Array[String] = [
	"Cirrus",
	"Cirrocumulus",
	"Altocumulus",
	"Stratocumulus",
	"Stratus",
	"Cumulus",
	"Cumulonimbus",
	"Nimbostratus",
	"Altostratus",
	"Cirrostratus"
]

@export_range(8, 30, 1) var formation_count: int = 20
@export var cloud_radius: float = 520.0
@export var drift_speed: Vector2 = Vector2(-0.8, 0.15)
@export_range(16, 64, 1) var raymarch_steps: int = 36

## Optional: assign a WorldEnvironment to add far-horizon volumetric clouds.
## This replaces that Environment's existing Sky, so it is off by default.
@export var use_distant_sky: bool = false
@export var distant_environment: WorldEnvironment

## Optional sun. If assigned, the nearby cloud lighting follows it.
@export var sun_light: DirectionalLight3D

var _player: Node3D
var _rng := RandomNumberGenerator.new()
var _formations: Array[MeshInstance3D] = []
var _base_noise: NoiseTexture3D
var _detail_noise: NoiseTexture3D
var _light_update_clock: float = 0.0


func setup(player: Node3D, _count: int = 45) -> void:
	_player = player
	_rng.randomize()

	if _base_noise == null or _detail_noise == null:
		_create_noise_textures()

	# Clear only previously generated volumes if setup() is called again.
	for formation in _formations:
		if is_instance_valid(formation):
			formation.queue_free()
	_formations.clear()

	for i in range(formation_count):
		var type_name: String = CLOUD_TYPES[i % CLOUD_TYPES.size()]
		_create_formation(type_name, i)

	_update_light_direction()

	if use_distant_sky and is_instance_valid(distant_environment):
		_install_distant_sky()


func _create_noise_textures() -> void:
	# NoiseTexture3D gives the raymarcher a real 3D density field instead of
	# the flat texture used by the old billboard lobes.
	_base_noise = _make_noise_texture(64, _rng.randi(), 0.055, 4)
	_detail_noise = _make_noise_texture(48, _rng.randi(), 0.12, 3)


func _make_noise_texture(size: int, seed_value: int, frequency: float, octaves: int) -> NoiseTexture3D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = 0.52
	noise.fractal_lacunarity = 2.0

	var texture_3d := NoiseTexture3D.new()
	texture_3d.width = size
	texture_3d.height = size
	texture_3d.depth = size
	texture_3d.seamless = true
	texture_3d.normalize = true
	texture_3d.noise = noise
	return texture_3d


func _create_formation(type_name: String, index: int) -> void:
	var volume := MeshInstance3D.new()
	volume.name = "%s_Volume_%02d" % [type_name, index]

	# A plain unit cube is only the raymarching boundary. The shader fades
	# density before the boundary, so the cube itself should never be visible.
	var box := BoxMesh.new()
	box.size = Vector3(2.0, 2.0, 2.0)
	volume.mesh = box

	var world_size: Vector3 = _get_volume_size(type_name)
	volume.scale = world_size * 0.5
	volume.material_override = _make_volume_material(type_name)

	var angle := _rng.randf_range(0.0, TAU)
	var radius := sqrt(_rng.randf()) * cloud_radius
	volume.position = Vector3(
		cos(angle) * radius,
		_get_height(type_name),
		sin(angle) * radius
	)

	add_child(volume)
	_formations.append(volume)


func _make_volume_material(type_name: String) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = VOLUME_SHADER
	material.set_shader_parameter("base_noise", _base_noise)
	material.set_shader_parameter("detail_noise", _detail_noise)
	material.set_shader_parameter("cloud_tint", _get_tint(type_name))
	material.set_shader_parameter("cloud_profile", float(CLOUD_TYPES.find(type_name)))
	material.set_shader_parameter("cloud_density", _get_density(type_name))
	material.set_shader_parameter("cloud_coverage", _get_coverage(type_name))
	material.set_shader_parameter("detail_strength", _get_detail_strength(type_name))
	material.set_shader_parameter("noise_stretch", _get_noise_stretch(type_name))
	material.set_shader_parameter("wind_direction", Vector3(1.0, 0.06, 0.22))
	material.set_shader_parameter("wind_speed", 0.0045)
	material.set_shader_parameter("light_direction", _get_light_direction())
	material.set_shader_parameter("max_steps", raymarch_steps)
	return material


func _get_tint(type_name: String) -> Color:
	# Sunset palette retained from the original code, now used for volume lighting.
	match type_name:
		"Cirrus": return Color(1.0, 0.87, 0.84, 0.32)
		"Cirrocumulus": return Color(1.0, 0.89, 0.85, 0.47)
		"Altocumulus": return Color(0.96, 0.76, 0.69, 0.57)
		"Stratocumulus": return Color(0.90, 0.68, 0.63, 0.66)
		"Stratus": return Color(0.78, 0.62, 0.66, 0.56)
		"Cumulus": return Color(1.0, 0.84, 0.76, 0.72)
		"Cumulonimbus": return Color(0.82, 0.61, 0.61, 0.78)
		"Nimbostratus": return Color(0.70, 0.58, 0.66, 0.72)
		"Altostratus": return Color(0.92, 0.72, 0.70, 0.53)
		"Cirrostratus": return Color(1.0, 0.89, 0.86, 0.32)
	return Color.WHITE


func _get_density(type_name: String) -> float:
	match type_name:
		"Cirrus", "Cirrostratus": return 0.58
		"Cirrocumulus", "Altocumulus": return 0.78
		"Stratus", "Altostratus": return 0.72
		"Stratocumulus": return 0.88
		"Cumulus": return 0.95
		"Cumulonimbus": return 1.12
		"Nimbostratus": return 1.05
	return 0.85


func _get_coverage(type_name: String) -> float:
	match type_name:
		"Cirrus", "Cirrostratus": return 0.42
		"Cirrocumulus", "Altocumulus": return 0.52
		"Stratus", "Altostratus", "Nimbostratus": return 0.72
		"Stratocumulus": return 0.61
		"Cumulonimbus": return 0.76
		"Cumulus": return 0.58
	return 0.55


func _get_detail_strength(type_name: String) -> float:
	match type_name:
		"Cirrus", "Cirrostratus": return 0.22
		"Stratus", "Altostratus", "Nimbostratus": return 0.30
		"Cumulonimbus": return 0.48
	return 0.38


func _get_noise_stretch(type_name: String) -> Vector3:
	# Stretching the sampled field creates wispy cirrus and broader layered clouds.
	match type_name:
		"Cirrus": return Vector3(1.6, 0.8, 0.34)
		"Cirrostratus": return Vector3(0.72, 1.7, 0.72)
		"Cirrocumulus": return Vector3(1.25, 1.0, 1.1)
		"Altocumulus": return Vector3(1.12, 0.92, 1.0)
		"Stratocumulus": return Vector3(1.25, 0.85, 1.0)
		"Stratus": return Vector3(0.85, 1.6, 0.85)
		"Nimbostratus": return Vector3(0.9, 1.35, 0.9)
		"Altostratus": return Vector3(0.8, 1.4, 0.8)
		"Cumulonimbus": return Vector3(0.95, 1.05, 0.95)
	return Vector3.ONE


func _get_volume_size(type_name: String) -> Vector3:
	match type_name:
		"Cirrus":
			return Vector3(_rng.randf_range(125.0, 205.0), _rng.randf_range(18.0, 32.0), _rng.randf_range(45.0, 85.0))
		"Cirrocumulus":
			return Vector3(_rng.randf_range(70.0, 115.0), _rng.randf_range(22.0, 38.0), _rng.randf_range(65.0, 105.0))
		"Altocumulus":
			return Vector3(_rng.randf_range(90.0, 155.0), _rng.randf_range(32.0, 58.0), _rng.randf_range(75.0, 130.0))
		"Stratocumulus":
			return Vector3(_rng.randf_range(145.0, 235.0), _rng.randf_range(24.0, 44.0), _rng.randf_range(110.0, 190.0))
		"Stratus":
			return Vector3(_rng.randf_range(210.0, 310.0), _rng.randf_range(17.0, 30.0), _rng.randf_range(175.0, 275.0))
		"Cumulus":
			return Vector3(_rng.randf_range(75.0, 130.0), _rng.randf_range(55.0, 95.0), _rng.randf_range(70.0, 135.0))
		"Cumulonimbus":
			return Vector3(_rng.randf_range(115.0, 175.0), _rng.randf_range(165.0, 260.0), _rng.randf_range(105.0, 170.0))
		"Nimbostratus":
			return Vector3(_rng.randf_range(200.0, 315.0), _rng.randf_range(48.0, 88.0), _rng.randf_range(175.0, 295.0))
		"Altostratus":
			return Vector3(_rng.randf_range(190.0, 280.0), _rng.randf_range(30.0, 54.0), _rng.randf_range(145.0, 245.0))
		"Cirrostratus":
			return Vector3(_rng.randf_range(230.0, 325.0), _rng.randf_range(13.0, 25.0), _rng.randf_range(190.0, 315.0))
	return Vector3(100.0, 55.0, 100.0)


func _get_height(type_name: String) -> float:
	match type_name:
		"Cirrus", "Cirrostratus": return _rng.randf_range(250.0, 350.0)
		"Cirrocumulus": return _rng.randf_range(220.0, 320.0)
		"Altocumulus", "Altostratus": return _rng.randf_range(140.0, 230.0)
		"Stratus", "Stratocumulus": return _rng.randf_range(45.0, 115.0)
		"Cumulus": return _rng.randf_range(65.0, 160.0)
		"Cumulonimbus": return _rng.randf_range(100.0, 220.0)
		"Nimbostratus": return _rng.randf_range(70.0, 140.0)
	return 100.0


func _get_light_direction() -> Vector3:
	if is_instance_valid(sun_light):
		# A DirectionalLight3D shines along its local -Z axis; +Z points back to the sun.
		return sun_light.global_basis.z.normalized()
	return Vector3(-0.4, 0.8, 0.25).normalized()


func _update_light_direction() -> void:
	var direction := _get_light_direction()
	for formation in _formations:
		if is_instance_valid(formation):
			var material := formation.material_override as ShaderMaterial
			if material != null:
				material.set_shader_parameter("light_direction", direction)


func _install_distant_sky() -> void:
	if not is_instance_valid(distant_environment):
		return

	if distant_environment.environment == null:
		distant_environment.environment = Environment.new()

	var sky := Sky.new()
	var sky_material := ShaderMaterial.new()
	sky_material.shader = DISTANT_SKY_SHADER
	sky_material.set_shader_parameter("base_noise", _base_noise)
	sky_material.set_shader_parameter("detail_noise", _detail_noise)
	sky_material.set_shader_parameter("cloud_coverage", 0.52)
	sky_material.set_shader_parameter("cloud_density", 0.80)
	sky_material.set_shader_parameter("cloud_noise_scale", 0.0032)
	sky_material.set_shader_parameter("detail_strength", 0.30)
	sky_material.set_shader_parameter("wind_direction", Vector2(1.0, 0.22))
	sky_material.set_shader_parameter("wind_speed", 0.0018)
	sky.sky_material = sky_material

	distant_environment.environment.sky = sky
	distant_environment.environment.background_mode = Environment.BG_SKY


func _process(delta: float) -> void:
	if not is_instance_valid(_player):
		return

	# Follow the aircraft on the horizontal plane while preserving cloud altitude.
	global_position.x = _player.global_position.x
	global_position.z = _player.global_position.z

	for formation in _formations:
		if not is_instance_valid(formation):
			continue

		formation.position.x += drift_speed.x * delta
		formation.position.z += drift_speed.y * delta

		var horizontal_distance := Vector2(formation.position.x, formation.position.z).length()
		if horizontal_distance > cloud_radius * 1.35:
			var angle := _rng.randf_range(0.0, TAU)
			var radius := _rng.randf_range(cloud_radius * 0.72, cloud_radius)
			formation.position.x = cos(angle) * radius
			formation.position.z = sin(angle) * radius

	_light_update_clock += delta
	if _light_update_clock >= 0.25:
		_light_update_clock = 0.0
		_update_light_direction()
