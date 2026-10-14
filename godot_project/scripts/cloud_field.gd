
extends Node3D
## Canyon Skies — procedural, layered cloud formations.
## Godot 4.x

var _player: Node3D


func setup(player: Node3D, _count: int = 45) -> void:
	_player = player

	# High altitude: thin, elongated cloud wisps.
	_add_layer(
		"CirrusLayer",
		250.0, 370.0,
		65,
		Vector2(5.0, 1.3),
		Color(1.0, 0.91, 0.88, 0.50),
		11,
		600.0
	)

	# Mid altitude: large, irregular cloud banks.
	_add_layer(
		"AltoLayer",
		120.0, 220.0,
		100,
		Vector2(3.2, 2.0),
		Color(0.94, 0.66, 0.56, 0.68),
		27,
		600.0
	)

	# Low altitude: dense clouds with darker sunset undersides.
	_add_layer(
		"CumulusLayer",
		40.0, 105.0,
		75,
		Vector2(2.7, 2.2),
		Color(0.83, 0.49, 0.42, 0.76),
		43,
		600.0
	)


func _add_layer(
	layer_name: String,
	min_height: float,
	max_height: float,
	particle_count: int,
	cloud_shape: Vector2,
	tint: Color,
	seed_value: int,
	spread: float
) -> void:
	var particles := GPUParticles3D.new()
	particles.name = layer_name
	particles.amount = particle_count
	particles.lifetime = 65.0
	particles.preprocess = 20.0
	particles.explosiveness = 0.0
	particles.randomness = 0.65
	particles.emitting = true

	particles.visibility_aabb = AABB(
		Vector3(-900, -250, -900),
		Vector3(1800, 650, 1800)
	)

	particles.position.y = (min_height + max_height) * 0.5

	var process_mat := ParticleProcessMaterial.new()
	process_mat.emission_shape = (
		ParticleProcessMaterial.EMISSION_SHAPE_BOX
	)
	process_mat.emission_box_extents = Vector3(
		spread,
		(max_height - min_height) * 0.5,
		spread
	)

	# Slow horizontal drift.
	process_mat.direction = Vector3(-1.0, 0.025, 0.12).normalized()
	process_mat.initial_velocity_min = 0.5
	process_mat.initial_velocity_max = 2.0
	process_mat.gravity = Vector3.ZERO
	process_mat.damping_min = 0.05
	process_mat.damping_max = 0.25

	# Avoid excessively large, uniform cloud blobs.
	process_mat.scale_min = 9.0
	process_mat.scale_max = 20.0

	# Give each altitude layer its own color variation.
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([
		0.0, 0.18, 0.55, 0.82, 1.0
	])
	gradient.colors = PackedColorArray([
		Color(tint.r, tint.g, tint.b, 0.0),
		Color(1.0, 0.91, 0.86, tint.a * 0.8),
		tint,
		Color(0.36, 0.24, 0.34, tint.a * 0.75),
		Color(0.28, 0.24, 0.36, 0.0)
	])

	var color_texture := GradientTexture1D.new()
	color_texture.gradient = gradient
	process_mat.color_ramp = color_texture
	particles.process_material = process_mat

	# Wide sprites produce cloud banks instead of round particles.
	var quad := QuadMesh.new()
	quad.size = cloud_shape
	particles.draw_pass_1 = quad

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _make_cloud_texture(seed_value)
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	particles.material_override = mat
	add_child(particles)


func _make_cloud_texture(seed_value: int) -> ImageTexture:
	# Generate fractal noise for irregular, multi-lobed silhouettes.
	const SIZE := 256

	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.022
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.52

	# A second noise field warps the outline.
	var warp_noise := FastNoiseLite.new()
	warp_noise.seed = seed_value + 101
	warp_noise.frequency = 0.045
	warp_noise.fractal_octaves = 3

	var img := Image.create(
		SIZE, SIZE, false, Image.FORMAT_RGBA8
	)

	for y in range(SIZE):
		for x in range(SIZE):
			var u := (float(x) / (SIZE - 1)) * 2.0 - 1.0
			var v := (float(y) / (SIZE - 1)) * 2.0 - 1.0

			# Distort the coordinates to prevent perfect circles.
			var warp_x := warp_noise.get_noise_2d(
				float(x) + 300.0, float(y)
			)
			var warp_y := warp_noise.get_noise_2d(
				float(x), float(y) + 500.0
			)

			var px := u + warp_x * 0.18
			var py := v + warp_y * 0.14

			# Elliptical envelope with uneven edges.
			var dist := sqrt(
				px * px * 0.8 + py * py * 1.1
			)

			var n := noise.get_noise_2d(
				px * 180.0 + 700.0,
				py * 180.0 + 900.0
			)

			# Combine broad shapes with fine edge detail.
			var density := n * 0.5 + 0.5
			var envelope := 1.0 - smoothstep(
				0.48, 1.12, dist
			)

			# Break up the outer boundary while retaining
			# a dense central region.
			var threshold := lerpf(
				0.63, 0.34, envelope
			)

			var alpha := smoothstep(
				threshold - 0.10,
				threshold + 0.15,
				density
			) * envelope

			# Fade the very outer edge smoothly.
			alpha *= smoothstep(0.0, 0.16, envelope)

			img.set_pixel(
				x, y,
				Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0))
			)

	return ImageTexture.create_from_image(img)


func _process(_delta: float) -> void:
	if not is_instance_valid(_player):
		return

	# Keep the cloud volume around the aircraft so the
	# player can fly through it without reaching its edge.
	for child in get_children():
		if child is GPUParticles3D:
			child.global_position = Vector3(
				_player.global_position.x,
				child.global_position.y,
				_player.global_position.z
			)
