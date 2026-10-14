extends Node3D
## Endless Perlin-noise canyon terrain, generated in chunks around a focus point.
## Heights = fBm Perlin (mesa bodies) + ridged Perlin (canyon walls) + detail, then terraced.
## Colour = height gradient + sedimentary strata + slope rock + noise blotches (vertex colours).

@export var seed_value: int = 1337
@export var chunk_size: float = 192.0
@export var chunk_res: int = 48
@export var view_chunks: int = 6
@export var height_scale: float = 260.0
@export var terrace_steps: float = 7.0
@export var terrace_strength: float = 0.55
@export var chunks_per_frame: int = 1

const ROCK := Color(0.36, 0.15, 0.13)
const ROCK_WARM := Color(0.60, 0.22, 0.15)

var _base := FastNoiseLite.new()
var _ridge := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _tint := FastNoiseLite.new()
var _gradient := Gradient.new()
var _material := ShaderMaterial.new()
var _chunks := {}   # Vector2i -> MeshInstance3D


func _ready() -> void:
	_setup_noise()
	_setup_gradient()
	_setup_material()


func _setup_noise() -> void:
	_base.noise_type = FastNoiseLite.TYPE_PERLIN
	_base.seed = seed_value
	_base.frequency = 0.0016
	_base.fractal_type = FastNoiseLite.FRACTAL_FBM
	_base.fractal_octaves = 5
	_base.fractal_gain = 0.5

	_ridge.noise_type = FastNoiseLite.TYPE_PERLIN
	_ridge.seed = seed_value + 101
	_ridge.frequency = 0.0042
	_ridge.fractal_type = FastNoiseLite.FRACTAL_FBM
	_ridge.fractal_octaves = 3

	_detail.noise_type = FastNoiseLite.TYPE_PERLIN
	_detail.seed = seed_value + 202
	_detail.frequency = 0.02
	_detail.fractal_octaves = 2

	_tint.noise_type = FastNoiseLite.TYPE_PERLIN
	_tint.seed = seed_value + 303
	_tint.frequency = 0.02
	_tint.fractal_octaves = 3


func _setup_gradient() -> void:
	# low -> high (sRGB): violet haze valleys, rose, rust, orange, peach, pale sand
	_gradient.offsets = PackedFloat32Array([0.0, 0.18, 0.38, 0.62, 0.85, 1.0])
	_gradient.colors = PackedColorArray([
		Color(0.33, 0.30, 0.50),
		Color(0.62, 0.33, 0.34),
		Color(0.80, 0.34, 0.16),
		Color(0.88, 0.50, 0.27),
		Color(0.96, 0.72, 0.52),
		Color(0.98, 0.84, 0.70),
	])


func _setup_material() -> void:
	_material.shader = load("res://shaders/terrain.gdshader")
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.03
	n.fractal_octaves = 4
	var img: Image = n.get_seamless_image(256, 256)
	_material.set_shader_parameter("detail_tex", ImageTexture.create_from_image(img))


# ---------------------------------------------------------------- height + colour
func height_at(x: float, z: float) -> float:
	var b := clampf(_base.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)
	var r := 1.0 - absf(_ridge.get_noise_2d(x, z))
	r = r * r
	var d := _detail.get_noise_2d(x, z) * 0.5 + 0.5
	var h := b * 0.62 + r * 0.30 + d * 0.08
	h = clampf((h - 0.22) / 0.55, 0.0, 1.0)
	h = lerpf(h, _terrace(h), terrace_strength)
	return pow(h, 1.35) * height_scale


func _terrace(h: float) -> float:
	var s := h * terrace_steps
	var f := floorf(s)
	var fr := smoothstep(0.30, 0.70, s - f)
	return (f + fr) / terrace_steps


func _color_at(x: float, z: float, h: float, ny: float) -> Color:
	var t := clampf(h / height_scale, 0.0, 1.0)
	var c: Color = _gradient.sample(t)
	var warp := _tint.get_noise_2d(x * 0.3, z * 0.3) * 1.5
	var strata := sin(h * 0.28 + warp) * 0.5 + 0.5
	c = c.lerp(c.darkened(0.28), smoothstep(0.55, 1.0, strata) * 0.55)
	var blotch := _tint.get_noise_2d(x, z) * 0.5 + 0.5
	c = c.lerp(ROCK_WARM, smoothstep(0.55, 0.9, blotch) * 0.22)
	c = c.lerp(ROCK, smoothstep(0.18, 0.55, 1.0 - ny) * 0.75)
	return c.srgb_to_linear()


# ---------------------------------------------------------------- chunks
func _build_chunk(c: Vector2i) -> MeshInstance3D:
	var n := chunk_res
	var step := chunk_size / float(n)
	var ox := c.x * chunk_size
	var oz := c.y * chunk_size
	var w := n + 3
	var heights := PackedFloat32Array()
	heights.resize(w * w)
	for iz in w:
		for ix in w:
			heights[iz * w + ix] = height_at(ox + (ix - 1) * step, oz + (iz - 1) * step)

	var count := (n + 1) * (n + 1)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(count)
	normals.resize(count)
	colors.resize(count)
	for iz in range(n + 1):
		for ix in range(n + 1):
			var gi := (iz + 1) * w + (ix + 1)
			var h := heights[gi]
			var nrm := Vector3(heights[gi - 1] - heights[gi + 1], 2.0 * step, heights[gi - w] - heights[gi + w]).normalized()
			var idx := iz * (n + 1) + ix
			verts[idx] = Vector3(ix * step, h, iz * step)
			normals[idx] = nrm
			colors[idx] = _color_at(ox + ix * step, oz + iz * step, h, nrm.y)

	var indices := PackedInt32Array()
	indices.resize(n * n * 6)
	var k := 0
	for iz in n:
		for ix in n:
			var i00 := iz * (n + 1) + ix
			var i10 := i00 + 1
			var i01 := i00 + (n + 1)
			var i11 := i01 + 1
			indices[k] = i00; indices[k + 1] = i10; indices[k + 2] = i01
			indices[k + 3] = i10; indices[k + 4] = i11; indices[k + 5] = i01
			k += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _material
	mi.position = Vector3(ox, 0.0, oz)
	return mi


func prewarm(focus: Vector3, radius: int = 2) -> void:
	var cc := _chunk_of(focus)
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			_ensure(cc + Vector2i(dx, dz))


func update_chunks(focus: Vector3) -> void:
	var cc := _chunk_of(focus)
	for key in _chunks.keys():
		if absi(key.x - cc.x) > view_chunks + 1 or absi(key.y - cc.y) > view_chunks + 1:
			_chunks[key].queue_free()
			_chunks.erase(key)
	var wanted: Array[Vector2i] = []
	for dz in range(-view_chunks, view_chunks + 1):
		for dx in range(-view_chunks, view_chunks + 1):
			if dx * dx + dz * dz <= view_chunks * view_chunks:
				var key := cc + Vector2i(dx, dz)
				if not _chunks.has(key):
					wanted.append(key)
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - cc).length_squared() < (b - cc).length_squared())
	for i in mini(chunks_per_frame, wanted.size()):
		_ensure(wanted[i])


func _ensure(key: Vector2i) -> void:
	if _chunks.has(key):
		return
	var mi := _build_chunk(key)
	add_child(mi)
	_chunks[key] = mi


func _chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / chunk_size), floori(p.z / chunk_size))
