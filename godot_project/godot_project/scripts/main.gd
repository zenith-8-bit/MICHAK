extends Node3D
## Canyon Skies - wires everything together.

const TerrainScript := preload("res://scripts/terrain_generator.gd")
const PlaneScript := preload("res://scripts/plane_controller.gd")
const FlockScript := preload("res://scripts/manta_flock.gd")
const CloudScript := preload("res://scripts/cloud_field.gd")
const GuardScript := preload("res://scripts/terrain_guard.gd")
const HudScript := preload("res://scripts/flight_hud.gd")
const CameraScript := preload("res://scripts/camera_director.gd")

var terrain: Node3D
var plane: Node3D
var cam: Camera3D
var hud: CanvasLayer
var camera_fx: Node
var music_player: AudioStreamPlayer
var music_volume_db: float = -12.0
var wind_player: AudioStreamPlayer
var sun: DirectionalLight3D
var guard: Node
var post_quad: MeshInstance3D
var post_material: ShaderMaterial
var _post_debug: int = 0
var flock   # untyped on purpose: manta_flock.gd's setup() is called on it
var _warned_shader_material := false

## Value the plane and mantas write into the stencil buffer. Must match the
## reference in painterly_post.gdshader (stencil_mode read, compare_not_equal, 1).
const SUBJECT_STENCIL_REF := 1

const WIND_NORMAL_DB := -28.0
const WIND_BOOST_DB := -8.0
const WIND_BRAKE_DB := -38.0

# Height above the ground at the spawn point.
const SPAWN_CLEARANCE := 260.0


func _ready() -> void:
	process_priority = 100

	_make_environment()
	_setup_music()
	_setup_wind()

	terrain = TerrainScript.new()
	terrain.name = "Terrain"
	add_child(terrain)

	# Terrain's _ready() has configured noise, palette and shader by now.
	# Tell the shader where the sun is so it can split warm/cool tones.
	terrain.call("set_sun_direction", sun.global_transform.basis.z)
	terrain.call("prewarm", Vector3.ZERO, 2)

	plane = PlaneScript.new()
	plane.set("terrain", terrain)
	add_child(plane)

	plane.call("setup", load("res://assets/models/plane.glb"))

	# Spawn relative to the actual ground so the terrain is close
	# enough to read, instead of a fixed 340 m above it.
	var ground: float = float(terrain.call("height_at", 0.0, 0.0))
	plane.position = Vector3(0, ground + SPAWN_CLEARANCE, 0)

	# Keeps the plane high above the ground and evades terrain ahead.
	guard = GuardScript.new()
	guard.name = "TerrainGuard"
	add_child(guard)
	guard.call("setup", plane, terrain)

	flock = FlockScript.new()
	add_child(flock)
	flock.setup(
		load("res://assets/models/manta.glb"),
		terrain,
		plane,
		7
	)

	var clouds := CloudScript.new()
	add_child(clouds)
	clouds.setup(plane, 45)

	cam = Camera3D.new()
	cam.fov = 70.0
	cam.far = 4000.0
	add_child(cam)
	cam.make_current()

	cam.global_position = plane.global_transform * Vector3(0, 4.5, 15)

	# Painted-dusk flight HUD (speed, altitude above ground, warnings).
	hud = HudScript.new()
	hud.name = "FlightHUD"
	add_child(hud)
	hud.call("setup", plane, terrain, guard)

	# Spring chase camera, focal breathing and the red/green edge tint.
	camera_fx = CameraScript.new()
	camera_fx.name = "CameraDirector"
	add_child(camera_fx)
	camera_fx.call("setup", cam, plane, flock, guard, terrain)

	_mask_subjects()
	_setup_post_fx()


# ---------------------------------------------------------
# Subject mask: keep the plane and mantas out of the painterly pass
# ---------------------------------------------------------

func _stencil_supported() -> bool:
	# Stencil support in materials and shaders arrived in Godot 4.5.
	var v := Engine.get_version_info()
	return int(v["major"]) > 4 or (int(v["major"]) == 4 and int(v["minor"]) >= 5)


func _mask_subjects() -> void:
	if not _stencil_supported():
		push_warning("Godot < 4.5: cannot mask plane/mantas from the painterly pass.")
		return

	# Mark everything that exists now...
	_mark_subject_tree(plane)
	_mark_subject_tree(flock)

	# ...and anything the plane or flock adds later (new mantas, swapped models).
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if not (n is MeshInstance3D):
		return
	var from_plane: bool = is_instance_valid(plane) and plane.is_ancestor_of(n)
	var from_flock: bool = is_instance_valid(flock) and flock.is_ancestor_of(n)
	if from_plane or from_flock:
		# Deferred so the owner can finish assigning materials first.
		call_deferred("_mark_mesh", n)


func _mark_subject_tree(root: Node) -> void:
	if not is_instance_valid(root):
		return
	if root is MeshInstance3D:
		_mark_mesh(root)
	for child in root.get_children():
		_mark_subject_tree(child)


func _mark_mesh(mi: MeshInstance3D) -> void:
	if not is_instance_valid(mi):
		return
	if mi.material_override != null:
		_mark_material(mi.material_override)
	if mi.mesh == null:
		return
	for s in mi.mesh.get_surface_count():
		var mat: Material = mi.get_active_material(s)
		if mat != null:
			_mark_material(mat)


## Makes a material write SUBJECT_STENCIL_REF into the stencil buffer while it
## draws normally. Property names are checked at runtime and plain integers are
## used for the enums, so the script still parses on engines without stencil.
func _mark_material(mat: Material) -> void:
	if mat is BaseMaterial3D and "stencil_mode" in mat:
		if int(mat.get("stencil_mode")) == 3 and int(mat.get("stencil_reference")) == SUBJECT_STENCIL_REF:
			return   # already marked (materials are shared between meshes)
		mat.set("stencil_mode", 3)        # STENCIL_MODE_CUSTOM
		mat.set("stencil_flags", 2)       # STENCIL_FLAG_WRITE
		mat.set("stencil_compare", 0)     # STENCIL_COMPARE_ALWAYS
		mat.set("stencil_reference", SUBJECT_STENCIL_REF)
	elif not _warned_shader_material:
		_warned_shader_material = true
		push_warning(
			"A plane/manta material is a ShaderMaterial (or has no stencil support). "
			+ "Add `stencil_mode write, compare_always, 1;` to its shader so it is masked too."
		)


# ---------------------------------------------------------
# Painterly post pass
# ---------------------------------------------------------

func _setup_post_fx() -> void:
	# The pass reads the depth buffer, so it needs Forward+ or Mobile.
	var method: String = RenderingServer.get_current_rendering_method()
	if method == "gl_compatibility":
		push_warning("Painterly post pass needs Forward+ or Mobile; skipped.")
		return

	# The masked version needs stencil (Godot 4.5+); older engines get the
	# unmasked shader, which would otherwise fail to compile.
	var shader_path := "res://shaders/painterly_post.gdshader"
	if not _stencil_supported():
		shader_path = "res://shaders/painterly_post_nostencil.gdshader"

	var shader := load(shader_path) as Shader
	if shader == null:
		push_warning("Missing shader: " + shader_path)
		return

	# Soft fibrous noise for the paper / canvas overlay.
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = 4242
	noise.frequency = 0.06
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3

	var image := noise.get_seamless_image(512, 512)
	image.generate_mipmaps()

	post_material = ShaderMaterial.new()
	post_material.shader = shader
	# The post pass paints over anything drawn before it. Boost VFX in
	# plane_controller.gd use render_priority 110 so they draw AFTER this pass
	# and stay bright and unpainted. Keep this below that value.
	post_material.render_priority = 100
	post_material.set_shader_parameter(
		"paper_tex", ImageTexture.create_from_image(image)
	)

	# Full-screen quad glued to the camera (the shader writes POSITION
	# directly, so it always covers the screen).
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)

	post_quad = MeshInstance3D.new()
	post_quad.name = "PainterlyPost"
	post_quad.mesh = quad
	post_quad.material_override = post_material
	post_quad.extra_cull_margin = 16384.0
	post_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cam.add_child(post_quad)


## F1 toggles the painterly pass. F2 cycles debug views:
## 0 final, 1 raw, 2 kuwahara, 3 edges, 4 flow, 5 fog, 6 depth.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return

	var key := event as InputEventKey
	if not key.pressed or key.echo or not is_instance_valid(post_quad):
		return

	if key.keycode == KEY_F1:
		post_quad.visible = not post_quad.visible
	elif key.keycode == KEY_F2:
		_post_debug = (_post_debug + 1) % 7
		post_material.set_shader_parameter("debug_view", _post_debug)


func _load_looping(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		push_warning("Missing audio file: " + path)
		return null

	var stream := load(path) as AudioStream

	# MP3 streams only loop if this flag is set; otherwise the
	# wind would play once and then go silent.
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true

	return stream


func _setup_music() -> void:
	music_player = AudioStreamPlayer.new()
	music_player.name = "BackgroundMusic"

	# Fall back to Master if there is no "Music" bus in the project.
	music_player.bus = (
		"Music" if AudioServer.get_bus_index("Music") != -1 else "Master"
	)
	music_player.volume_db = music_volume_db
	music_player.stream = _load_looping("res://assets/audio/main_track.mp3")

	add_child(music_player)

	if music_player.stream:
		music_player.play()


func _setup_wind() -> void:
	wind_player = AudioStreamPlayer.new()
	wind_player.name = "FlightWind"
	wind_player.bus = "Master"
	wind_player.volume_db = WIND_NORMAL_DB
	wind_player.stream = _load_looping("res://assets/audio/flight_wind.mp3")

	add_child(wind_player)

	if wind_player.stream:
		wind_player.play()


# ---------------------------------------------------------
# Environment
# ---------------------------------------------------------

func _make_environment() -> void:
	var cloud_shader: Shader = preload("res://shaders/canyon_clouds.gdshader")

	var sky_material := ShaderMaterial.new()
	sky_material.shader = cloud_shader

	sky_material.set_shader_parameter("cloud_coverage", 0.49)
	sky_material.set_shader_parameter("cloud_softness", 0.16)
	sky_material.set_shader_parameter("cloud_opacity", 0.94)
	sky_material.set_shader_parameter("cloud_scale", 1.5)
	sky_material.set_shader_parameter("wind_speed", 0.012)
	sky_material.set_shader_parameter("cloud_detail", 0.42)

	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky

	# The sky is bright peach; using it as ambient light flattened
	# the whole terrain. A dim mauve ambient keeps shadows deep.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.30, 0.46)
	env.ambient_light_energy = 0.70

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.3
	env.glow_bloom = 0.02

	# Fog was the main problem: at 0.0019 almost everything past
	# ~800 m was fully fogged, hiding the whole terrain. Lower density
	# and a darker mauve color give depth without erasing the land.
	env.fog_enabled = true
	env.fog_light_color = Color(0.74, 0.54, 0.46)
	env.fog_density = 0.0007
	env.fog_sky_affect = 0.35

	env.adjustment_enabled = true
	env.adjustment_saturation = 1.15
	env.adjustment_contrast = 1.12

	var world_environment := WorldEnvironment.new()
	world_environment.environment = env
	add_child(world_environment)

	sun = DirectionalLight3D.new()
	# Key light from the upper-left; shadows fall to the right.
	sun.rotation_degrees = Vector3(-34, -68, 0)
	sun.light_color = Color(1.0, 0.82, 0.58)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 1100.0
	add_child(sun)


# ---------------------------------------------------------
# Per-frame
# ---------------------------------------------------------

func _process(delta: float) -> void:
	if Input.is_key_pressed(KEY_ESCAPE):
		get_tree().quit()
		return

	if not is_instance_valid(plane) or not is_instance_valid(terrain):
		return

	_update_wind(delta)

	terrain.call("update_chunks", plane.global_position)
	# The chase camera lives in camera_director.gd (priority 101, runs after this).


func _update_wind(delta: float) -> void:
	if not is_instance_valid(wind_player):
		return

	var target_db := WIND_NORMAL_DB

	if Input.is_key_pressed(KEY_CTRL):
		target_db = WIND_BRAKE_DB
	elif Input.is_key_pressed(KEY_SHIFT):
		target_db = WIND_BOOST_DB
	else:
		var speed_ratio := clampf(
			float(plane.get("speed")) / 250.0, 0.0, 1.0
		)
		target_db = lerpf(-28.0, -16.0, speed_ratio)

	var blend := 1.0 - exp(-3.5 * delta)
	wind_player.volume_db = lerpf(wind_player.volume_db, target_db, blend)

	# Pitch rides the throttle: higher in boost, lower when the airbrake is out.
	var boost: float = float(plane.get("boost_amount"))
	var brake: float = float(plane.get("brake_amount"))
	wind_player.pitch_scale = lerpf(wind_player.pitch_scale, 1.0 + 0.22 * boost - 0.15 * brake, blend)
