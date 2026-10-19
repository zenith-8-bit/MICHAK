extends Node3D
## Canyon Skies - painterly canyon terrain.
## Art direction: sweeping diagonal mesa ridges (top-left -> bottom-right),
## sunlit ochre / terracotta surfaces against deep violet-brown shadows,
## a thin teal river on the canyon floor, matte chalk-brushed texture.

# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

@export_group("Terrain")
@export var seed_value: int = 1337
@export var chunk_size: float = 192.0
@export_range(16, 128, 1) var chunk_res: int = 48
@export_range(1, 10, 1) var view_chunks: int = 7
@export var height_scale: float = 130.0

@export_group("Landforms")
@export_range(0.0, 1.0, 0.01) var mesa_strength: float = 0.70
@export_range(0.0, 1.0, 0.01) var canyon_strength: float = 0.18
@export_range(0.0, 1.0, 0.01) var ridge_strength: float = 0.50
@export_range(0.0, 1.0, 0.01) var river_strength: float = 1.0
@export_range(0.0, 0.25, 0.005) var detail_strength: float = 0.03
@export_range(0.0, 1.0, 0.01) var spire_strength: float = 0.55

@export_group("Streaming")
@export_range(1, 8, 1) var chunks_per_frame: int = 1

# Palette (sRGB, converted to linear when baked).
const ROCK := Color(0.17, 0.09, 0.13)        # sepia / violet-brown shadow
const ROCK_WARM := Color(0.74, 0.33, 0.17)   # terracotta
const ROCK_COOL := Color(0.38, 0.30, 0.45)   # dusty lavender-gray
const OCHRE := Color(0.84, 0.60, 0.30)       # mustard ochre
const SALT := Color(0.55, 0.42, 0.62)        # violet salt flats
const MINERAL := Color(0.22, 0.46, 0.50)     # teal mineral basins
const BEIGE := Color(0.86, 0.72, 0.54)       # dusty beige

var _base: FastNoiseLite = FastNoiseLite.new()
var _secondary: FastNoiseLite = FastNoiseLite.new()
var _detail: FastNoiseLite = FastNoiseLite.new()
var _ridge: FastNoiseLite = FastNoiseLite.new()
var _river: FastNoiseLite = FastNoiseLite.new()
var _warp_x: FastNoiseLite = FastNoiseLite.new()
var _warp_z: FastNoiseLite = FastNoiseLite.new()
var _tint: FastNoiseLite = FastNoiseLite.new()
var _biome: FastNoiseLite = FastNoiseLite.new()
var _spire: FastNoiseLite = FastNoiseLite.new()
var _oil: FastNoiseLite = FastNoiseLite.new()

## World positions (y = ground) of the oil seeps the contractor wants surveyed.
var oil_sites: Array[Vector3] = []

var _gradient: Gradient = Gradient.new()
var _material: ShaderMaterial = ShaderMaterial.new()

var _chunks: Dictionary = {}


# ---------------------------------------------------------
# Initialization
# ---------------------------------------------------------

func _ready() -> void:
	_setup_noise()
	_setup_gradient()
	_setup_material()
	oil_sites = find_oil_sites(5, 500.0, 2800.0, 650.0)


## Direction pointing TOWARD the sun, in world space.
## Lets the shader tint sunlit faces warm and shaded faces cool.
func set_sun_direction(dir: Vector3) -> void:
	_material.set_shader_parameter("sun_dir", dir.normalized())


# ---------------------------------------------------------
# Noise
# ---------------------------------------------------------

func _configure_noise(
	noise: FastNoiseLite,
	noise_seed: int,
	frequency: float,
	octaves: int,
	gain: float = 0.5
) -> void:
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.seed = noise_seed
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = gain
	noise.fractal_lacunarity = 2.0


func _setup_noise() -> void:
	_configure_noise(_base, seed_value, 0.0014, 4, 0.50)
	_configure_noise(_secondary, seed_value + 101, 0.0024, 3, 0.48)
	_configure_noise(_detail, seed_value + 202, 0.0070, 3, 0.50)
	_configure_noise(_ridge, seed_value + 707, 0.0042, 4, 0.50)
	# Smooth meanders for the river: few octaves, low gain.
	_configure_noise(_river, seed_value + 808, 0.0026, 2, 0.45)
	_configure_noise(_warp_x, seed_value + 303, 0.0011, 3, 0.5)
	_configure_noise(_warp_z, seed_value + 404, 0.0011, 3, 0.5)
	_configure_noise(_tint, seed_value + 505, 0.0040, 3, 0.5)
	_configure_noise(_biome, seed_value + 909, 0.0009, 2, 0.5)
	_configure_noise(_spire, seed_value + 1111, 0.0105, 3, 0.55)
	_configure_noise(_oil, seed_value + 1313, 0.0021, 2, 0.5)


## Rotate into diagonal space: x = along the top-left -> bottom-right
## direction, y = across it. Sampling noise with the along-axis
## compressed stretches every landform along that diagonal.
func _diag(x: float, z: float) -> Vector2:
	return Vector2((x + z) * 0.70710678, (z - x) * 0.70710678)


# ---------------------------------------------------------
# Palette (valley -> summit)
# ---------------------------------------------------------

func _setup_gradient() -> void:
	_gradient.offsets = PackedFloat32Array([
		0.0, 0.14, 0.30, 0.46, 0.62, 0.80, 1.0
	])

	_gradient.colors = PackedColorArray([
		Color(0.20, 0.11, 0.16),  # plum-sepia canyon floor
		Color(0.36, 0.16, 0.20),  # muted burgundy
		Color(0.58, 0.26, 0.16),  # burnt sienna
		Color(0.76, 0.36, 0.20),  # terracotta
		Color(0.84, 0.47, 0.24),  # rust orange
		Color(0.86, 0.62, 0.32),  # mustard ochre
		Color(0.88, 0.74, 0.55)   # dusty beige
	])


# ---------------------------------------------------------
# Painterly terrain shader
# ---------------------------------------------------------

func _setup_material() -> void:
	var shader_resource: Resource = load("res://shaders/terrain.gdshader")

	if shader_resource == null or not shader_resource is Shader:
		push_error("Missing terrain shader: res://shaders/terrain.gdshader")
		return

	_material.shader = shader_resource as Shader

	var texture_noise := FastNoiseLite.new()
	texture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	texture_noise.seed = seed_value + 606
	texture_noise.frequency = 0.025
	texture_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	texture_noise.fractal_octaves = 4
	texture_noise.fractal_gain = 0.52

	var noise_image := texture_noise.get_seamless_image(512, 512)

	if noise_image == null:
		push_warning("Could not generate terrain detail texture.")
		return

	_material.set_shader_parameter(
		"detail_tex", ImageTexture.create_from_image(noise_image)
	)
	_material.set_shader_parameter("detail_scale", 0.006)
	_material.set_shader_parameter("brush_scale", 0.02)
	_material.set_shader_parameter("color_patch_strength", 0.28)
	_material.set_shader_parameter("paint_blend", 0.5)
	_material.set_shader_parameter("strata_strength", 0.10)
	_material.set_shader_parameter("strata_scale", 0.09)
	_material.set_shader_parameter("chalk_strength", 0.24)
	_material.set_shader_parameter("color_variation", 0.14)
	_material.set_shader_parameter("warm_light_strength", 0.55)
	_material.set_shader_parameter("cool_shadow_strength", 0.60)
	_material.set_shader_parameter("terminator_hardness", 0.35)
	_material.set_shader_parameter("shadow_lift", 0.03)

	# Peaks a bit darker, flanks a bit lighter.
	_material.set_shader_parameter("height_scale", height_scale)
	_material.set_shader_parameter("peak_start", 0.55)
	_material.set_shader_parameter("peak_end", 0.82)
	_material.set_shader_parameter("peak_darken", 0.60)
	_material.set_shader_parameter("flank_lighten", 0.14)

	# Dither the far chunk edge away so streaming boundaries don't show.
	_material.set_shader_parameter(
		"fade_start", (float(view_chunks) - 2.2) * chunk_size
	)
	_material.set_shader_parameter(
		"fade_end", (float(view_chunks) - 1.0) * chunk_size
	)


# ---------------------------------------------------------
# River distance field
# ---------------------------------------------------------

## Distance-like value to the river centerline (0 = on the river).
## The river is the zero contour of a stretched, warped Perlin field,
## so it is one continuous winding line running along the diagonal.
func _river_d(x: float, z: float) -> float:
	var wx: float = x + _warp_x.get_noise_2d(x + 57.0, z - 91.0) * 45.0
	var wz: float = z + _warp_z.get_noise_2d(x - 133.0, z + 77.0) * 45.0
	var uv: Vector2 = _diag(wx, wz)
	return absf(_river.get_noise_2d(uv.x * 0.5, uv.y))


# ---------------------------------------------------------
# Terrain height
# ---------------------------------------------------------

func oil_noise(x: float, z: float) -> float:
	return _oil.get_noise_2d(x, z) * 0.5 + 0.5


## Picks the best low-lying, well-separated seep locations in an annulus
## around the origin. Deterministic for a given seed.
func find_oil_sites(count: int, min_r: float, max_r: float, min_sep: float) -> Array[Vector3]:
	var cands: Array[Dictionary] = []
	var step: float = 70.0
	var n: int = int(max_r / step)
	for iz in range(-n, n + 1):
		for ix in range(-n, n + 1):
			var x: float = float(ix) * step
			var z: float = float(iz) * step
			var r: float = Vector2(x, z).length()
			if r < min_r or r > max_r:
				continue
			var h: float = height_at(x, z) / maxf(height_scale, 0.001)
			if h > 0.34:
				continue
			cands.append({"pos": Vector3(x, 0.0, z), "score": oil_noise(x, z) - h * 0.4})
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))

	var out: Array[Vector3] = []
	for c in cands:
		var p: Vector3 = c["pos"]
		var ok: bool = true
		for q in out:
			if Vector2(p.x - q.x, p.z - q.z).length() < min_sep:
				ok = false
				break
		if ok:
			out.append(Vector3(p.x, height_at(p.x, p.z), p.z))
			if out.size() >= count:
				break
	return out


func height_at(x: float, z: float) -> float:
	var warp_amount: float = 95.0

	var wx: float = x + _warp_x.get_noise_2d(x, z) * warp_amount
	var wz: float = z + _warp_z.get_noise_2d(
		x + 731.0, z - 419.0
	) * warp_amount

	# Diagonal space: everything below is stretched along TL -> BR.
	var uv: Vector2 = _diag(wx, wz)

	var broad: float = _base.get_noise_2d(uv.x * 0.65, uv.y) * 0.5 + 0.5
	var secondary: float = _secondary.get_noise_2d(
		uv.x * 0.7, uv.y
	) * 0.5 + 0.5
	var detail: float = _detail.get_noise_2d(wx, wz)

	# Wide mesas with fairly crisp cliff shoulders.
	var plateau: float = smoothstep(0.36, 0.64, broad)
	var upper: float = smoothstep(0.52, 0.74, secondary) * plateau

	# Sharp eroded crest lines, long along the diagonal.
	var ridge_raw: float = _ridge.get_noise_2d(uv.x * 0.45, uv.y)
	var ridge: float = pow(1.0 - absf(ridge_raw), 2.6)
	var shoulder: float = plateau * (1.0 - plateau) * 4.0
	var ridge_mask: float = 0.25 + 0.55 * plateau + 0.35 * shoulder

	var h: float = 0.07 + 0.28 * broad
	h += mesa_strength * 0.40 * plateau
	h += 0.10 * upper

	# Needle spires: sparse hoodoos rising off the mesa tops.
	var spire_raw: float = _spire.get_noise_2d(wx, wz)
	var spire: float = pow(smoothstep(0.50, 0.88, spire_raw), 2.0)
	h += spire * spire_strength * 0.30 * (0.35 + 0.65 * plateau)
	h += ridge * ridge_strength * 0.20 * ridge_mask

	# Side gullies.
	var channel_noise: float = _base.get_noise_2d(
		uv.x * 0.3 + 913.0, uv.y * 0.6 - 527.0
	)
	var channel_width: float = lerpf(0.04, 0.13, secondary)
	var channel: float = 1.0 - smoothstep(
		channel_width, channel_width + 0.11, absf(channel_noise)
	)
	var valley_noise: float = _secondary.get_noise_2d(
		uv.x * 0.4 - 211.0, uv.y * 0.65 + 389.0
	)
	var broad_valley: float = 1.0 - smoothstep(
		0.08, 0.48, absf(valley_noise)
	)
	var canyon: float = clampf(channel * 0.7 + broad_valley * 0.3, 0.0, 1.0)
	h -= canyon_strength * canyon

	h += detail * detail_strength * (0.6 + 0.8 * shoulder)

	# Main river: carve a flat bed with canyon walls rising away from it.
	var d: float = _river_d(x, z)
	var wall: float = 0.05 + 0.95 * smoothstep(0.02, 0.40, d)
	h = lerpf(h, minf(h, wall), river_strength)

	return clampf(h, 0.035, 1.0) * height_scale


# ---------------------------------------------------------
# Vertex colors (alpha = river mask)
# ---------------------------------------------------------

func _color_at(
	x: float,
	z: float,
	h: float,
	normal_y: float
) -> Color:
	var t: float = clampf(h / maxf(height_scale, 0.001), 0.0, 1.0)

	var color: Color = _gradient.sample(t)

	var tint_a: float = _tint.get_noise_2d(x, z) * 0.5 + 0.5
	var tint_b: float = _secondary.get_noise_2d(
		x * 0.7 + 350.0, z * 0.7
	) * 0.5 + 0.5
	var tint_c: float = _warp_x.get_noise_2d(
		x * 1.8 + 90.0, z * 1.8
	) * 0.5 + 0.5

	# Loose warm / cool pigment patches independent of height.
	color = color.lerp(ROCK_WARM, smoothstep(0.45, 0.80, tint_a) * 0.40)
	color = color.lerp(ROCK_COOL, smoothstep(0.55, 0.85, tint_b) * 0.32)

	# High flat ground: dry ochre and beige soil.
	var flat_ground: float = smoothstep(0.72, 0.96, normal_y)
	var high_flat: float = flat_ground * smoothstep(0.45, 0.85, t)
	color = color.lerp(OCHRE, high_flat * 0.60)
	color = color.lerp(BEIGE, high_flat * smoothstep(0.50, 0.80, tint_c) * 0.55)

	# Soft sediment bands.
	var warp: float = _tint.get_noise_2d(x * 0.25, z * 0.25) * 1.4
	var band: float = smoothstep(0.68, 0.98, absf(sin(h * 0.12 + warp)))
	color = color.lerp(color.darkened(0.22), band * 0.12)

	# Steep walls drop toward violet-brown.
	var slope: float = 1.0 - smoothstep(0.45, 0.88, normal_y)
	var wall_color: Color = ROCK.lerp(
		ROCK_COOL, smoothstep(0.4, 0.8, tint_b) * 0.5
	)
	color = color.lerp(wall_color, slope * 0.55)

	# Low ground sits in cool plum shade.
	var low: float = 1.0 - smoothstep(0.0, 0.22, t)
	color = color.lerp(ROCK_COOL.darkened(0.45), low * 0.30)

	# Regional biomes: violet salt flats and teal mineral basins.
	var biome: float = _biome.get_noise_2d(x, z) * 0.5 + 0.5
	color = color.lerp(SALT, smoothstep(0.60, 0.82, biome) * 0.42 * (1.0 - t * 0.5))
	color = color.lerp(MINERAL, (1.0 - smoothstep(0.14, 0.34, biome)) * 0.38 * (1.0 - t))

	# Oil seeps: black pools with an iridescent sheen.
	var oil: float = smoothstep(0.68, 0.82, oil_noise(x, z)) * (1.0 - smoothstep(0.10, 0.34, t))
	for site in oil_sites:
		oil = maxf(oil, 1.0 - smoothstep(35.0, 95.0, Vector2(x - site.x, z - site.z).length()))
	if oil > 0.01:
		var hue: float = fposmod(0.52 + oil_noise(x * 3.0, z * 3.0) * 1.2 + x * 0.002, 1.0)
		var sheen: Color = Color.from_hsv(hue, 0.55, 0.42)
		var pool: Color = Color(0.04, 0.05, 0.07).lerp(sheen, 0.35)
		color = color.lerp(pool, clampf(oil, 0.0, 1.0) * 0.9)

	# River: damp, darker banks, then a water mask in alpha.
	var d: float = _river_d(x, z)
	var bank: float = 1.0 - smoothstep(0.02, 0.10, d)
	color = color.lerp(ROCK.lerp(ROCK_COOL, 0.4), bank * 0.40)

	var out: Color = color.srgb_to_linear()
	out.a = (1.0 - smoothstep(0.012, 0.026, d)) * river_strength
	return out


# ---------------------------------------------------------
# Mesh construction
# ---------------------------------------------------------

func _build_chunk(chunk: Vector2i) -> MeshInstance3D:
	var n: int = chunk_res
	var step: float = chunk_size / float(n)

	var ox: float = float(chunk.x) * chunk_size
	var oz: float = float(chunk.y) * chunk_size

	# Two-vertex border so normals can use a wider stencil and still
	# match across chunk edges.
	var width: int = n + 5

	var heights := PackedFloat32Array()
	heights.resize(width * width)

	for iz in range(width):
		for ix in range(width):
			var wx: float = ox + float(ix - 2) * step
			var wz: float = oz + float(iz - 2) * step
			heights[iz * width + ix] = height_at(wx, wz)

	var side: int = n + 1
	var vertex_count: int = side * side

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)

	for iz in range(side):
		for ix in range(side):
			var gi: int = (iz + 2) * width + ix + 2
			var h: float = heights[gi]

			# Blend 1-cell and 2-cell slopes for smoother, less faceted shading.
			var dhdx: float = (
				(heights[gi + 1] - heights[gi - 1]) / (2.0 * step) * 0.6
				+ (heights[gi + 2] - heights[gi - 2]) / (4.0 * step) * 0.4
			)
			var dhdz: float = (
				(heights[gi + width] - heights[gi - width]) / (2.0 * step) * 0.6
				+ (heights[gi + 2 * width] - heights[gi - 2 * width]) / (4.0 * step) * 0.4
			)
			var normal := Vector3(-dhdx, 1.0, -dhdz).normalized()

			var index: int = iz * side + ix

			var wx: float = ox + float(ix) * step
			var wz: float = oz + float(iz) * step

			vertices[index] = Vector3(float(ix) * step, h, float(iz) * step)
			normals[index] = normal
			colors[index] = _color_at(wx, wz, h, normal.y)

	var indices := PackedInt32Array()
	indices.resize(n * n * 6)

	var k: int = 0

	for iz in range(n):
		for ix in range(n):
			var i00: int = iz * side + ix
			var i10: int = i00 + 1
			var i01: int = i00 + side
			var i11: int = i01 + 1

			# Godot treats CLOCKWISE triangles as front-facing.
			indices[k] = i00
			indices[k + 1] = i10
			indices[k + 2] = i01

			indices[k + 3] = i10
			indices[k + 4] = i11
			indices[k + 5] = i01

			k += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)

	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var instance := MeshInstance3D.new()
	instance.name = "Terrain_%d_%d" % [chunk.x, chunk.y]
	instance.mesh = mesh
	instance.material_override = _material
	instance.position = Vector3(ox, 0.0, oz)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	return instance


# ---------------------------------------------------------
# Chunk helpers / streaming
# ---------------------------------------------------------

func _chunk_of(point: Vector3) -> Vector2i:
	return Vector2i(
		floori(point.x / chunk_size),
		floori(point.z / chunk_size)
	)


func prewarm(focus: Vector3, radius: int = 2) -> void:
	var center: Vector2i = _chunk_of(focus)

	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			_ensure(center + Vector2i(dx, dz))


func update_chunks(focus: Vector3) -> void:
	var center: Vector2i = _chunk_of(focus)

	for key in _chunks.keys():
		var chunk_key: Vector2i = key

		if (
			abs(chunk_key.x - center.x) > view_chunks + 1
			or abs(chunk_key.y - center.y) > view_chunks + 1
		):
			var old: MeshInstance3D = _chunks[chunk_key]
			old.queue_free()
			_chunks.erase(chunk_key)

	var wanted: Array[Vector2i] = []

	for dz in range(-view_chunks, view_chunks + 1):
		for dx in range(-view_chunks, view_chunks + 1):
			if dx * dx + dz * dz > view_chunks * view_chunks:
				continue

			var key: Vector2i = center + Vector2i(dx, dz)

			if not _chunks.has(key):
				wanted.append(key)

	wanted.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			return (
				(a - center).length_squared()
				< (b - center).length_squared()
			)
	)

	var amount: int = mini(chunks_per_frame, wanted.size())

	for i in range(amount):
		_ensure(wanted[i])


func _ensure(key: Vector2i) -> void:
	if _chunks.has(key):
		return

	var instance: MeshInstance3D = _build_chunk(key)

	add_child(instance)
	_chunks[key] = instance