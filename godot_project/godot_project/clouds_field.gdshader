shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled;

// A raymarched cloud volume. The BoxMesh is merely the ray interval; density
// comes from a 3D noise field and is accumulated along the view ray.
uniform sampler3D base_noise : filter_linear, repeat_enable;
uniform sampler3D detail_noise : filter_linear, repeat_enable;
uniform sampler2D scene_depth : hint_depth_texture, filter_nearest;

uniform vec4 cloud_tint : source_color = vec4(1.0, 0.84, 0.76, 0.72);
uniform float cloud_profile = 5.0;
uniform float cloud_density : hint_range(0.1, 2.0) = 0.95;
uniform float cloud_coverage : hint_range(0.1, 1.0) = 0.58;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.38;
uniform vec3 noise_stretch = vec3(1.0, 1.0, 1.0);
uniform vec3 wind_direction = vec3(1.0, 0.06, 0.22);
uniform float wind_speed : hint_range(0.0, 0.03) = 0.0045;
uniform vec3 light_direction = vec3(-0.4, 0.8, 0.25);
uniform int max_steps : hint_range(16, 64, 1) = 36;

varying vec3 local_position;
varying vec3 world_position;

void vertex() {
	local_position = VERTEX;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float safe_component(float value) {
	if (abs(value) < 0.00001) {
		return value < 0.0 ? -0.00001 : 0.00001;
	}
	return value;
}

float shape_density(vec3 p, float broad_noise, float detail_noise_value) {
	float profile = floor(cloud_profile + 0.5);
	float vertical_mask = smoothstep(-1.0, -0.76, p.y) * (1.0 - smoothstep(0.72, 1.0, p.y));
	float horizontal_radius = 1.0;

	// The profiles alter the volume's density envelope; no lobe sprites are used.
	if (profile < 0.5) { // Cirrus: stretched, thin wisps.
		vertical_mask = 1.0 - smoothstep(0.20, 0.92, abs(p.y + 0.02));
		horizontal_radius = 1.18;
	} else if (profile < 1.5) { // Cirrocumulus: fine, small puff clusters.
		vertical_mask *= 1.0 - smoothstep(0.74, 1.0, abs(p.y));
		horizontal_radius = 0.86;
	} else if (profile < 2.5) { // Altocumulus.
		vertical_mask *= 1.0 - smoothstep(0.82, 1.0, abs(p.y));
		horizontal_radius = 0.98;
	} else if (profile < 3.5) { // Stratocumulus: broad and low.
		vertical_mask = 1.0 - smoothstep(0.47, 0.96, abs(p.y + 0.02));
		horizontal_radius = 1.22;
	} else if (profile < 4.5) { // Stratus: flatter sheet.
		vertical_mask = 1.0 - smoothstep(0.34, 0.94, abs(p.y));
		horizontal_radius = 1.26;
	} else if (profile < 5.5) { // Cumulus: rounded top, narrower base.
		horizontal_radius = mix(0.68, 1.03, smoothstep(-1.0, 0.12, p.y));
		horizontal_radius *= 1.0 - 0.20 * smoothstep(0.50, 1.0, p.y);
	} else if (profile < 6.5) { // Cumulonimbus: rising, tower-like body.
		horizontal_radius = mix(0.62, 0.92, smoothstep(-1.0, 0.72, p.y));
		vertical_mask = smoothstep(-1.0, -0.80, p.y) * (1.0 - smoothstep(0.83, 1.0, p.y));
	} else if (profile < 7.5) { // Nimbostratus: dark, deep layer.
		vertical_mask = 1.0 - smoothstep(0.57, 1.0, abs(p.y + 0.04));
		horizontal_radius = 1.28;
	} else if (profile < 8.5) { // Altostratus.
		vertical_mask = 1.0 - smoothstep(0.48, 0.98, abs(p.y));
		horizontal_radius = 1.27;
	} else { // Cirrostratus: very thin high sheet.
		vertical_mask = 1.0 - smoothstep(0.25, 0.82, abs(p.y));
		horizontal_radius = 1.32;
	}

	float radial_distance = length(p.xz / vec2(horizontal_radius, horizontal_radius * 0.92));
	float edge_distortion = (broad_noise - 0.5) * 0.30 + (detail_noise_value - 0.5) * 0.10;
	float horizontal_mask = 1.0 - smoothstep(0.53, 1.12, radial_distance + edge_distortion);

	float threshold = 0.72 - cloud_coverage * 0.30;
	float eroded_noise = broad_noise + (detail_noise_value - 0.5) * detail_strength;
	float noise_fill = smoothstep(threshold - 0.13, threshold + 0.17, eroded_noise);

	return clamp(noise_fill * horizontal_mask * vertical_mask, 0.0, 1.0);
}

void fragment() {
	vec3 ray_origin_world = CAMERA_POSITION_WORLD;
	vec3 ray_direction_world = normalize(world_position - ray_origin_world);
	mat4 world_to_local = inverse(MODEL_MATRIX);
	vec3 ray_origin = (world_to_local * vec4(ray_origin_world, 1.0)).xyz;
	// Do not normalize this vector: t remains a world-space distance.
	vec3 ray_direction = (world_to_local * vec4(ray_direction_world, 0.0)).xyz;
	vec3 safe_ray = vec3(
		safe_component(ray_direction.x),
		safe_component(ray_direction.y),
		safe_component(ray_direction.z)
	);

	vec3 t_a = (-vec3(1.0) - ray_origin) / safe_ray;
	vec3 t_b = ( vec3(1.0) - ray_origin) / safe_ray;
	vec3 t_min = min(t_a, t_b);
	vec3 t_max = max(t_a, t_b);
	float t_enter = max(max(t_min.x, t_min.y), max(t_min.z, 0.0));
	float t_exit = min(min(t_max.x, t_max.y), t_max.z);
	if (t_exit <= t_enter + 0.01) {
		discard;
	}

	// cull_disabled lets the volume work when the camera is inside it. Only
	// shade the entry surface when outside, or the exit surface when inside.
	float surface_t = dot(local_position - ray_origin, ray_direction) / max(dot(ray_direction, ray_direction), 0.000001);
	bool camera_inside = all(lessThanEqual(abs(ray_origin), vec3(1.0)));
	if (!camera_inside && surface_t > t_enter + 0.04) {
		discard;
	}
	if (camera_inside && surface_t < t_exit - 0.04) {
		discard;
	}

	// Transparent volumes have depth testing disabled so a ray can be clipped
	// against opaque terrain using the scene depth instead of the cube's back face.
	float raw_scene_depth = texture(scene_depth, SCREEN_UV).r;
	if (raw_scene_depth < 0.999999) {
		vec4 scene_view_position = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw_scene_depth, 1.0);
		scene_view_position.xyz /= max(scene_view_position.w, 0.000001);
		float opaque_distance = length(scene_view_position.xyz);
		if (opaque_distance <= t_enter + 0.01) {
			discard;
		}
		t_exit = min(t_exit, opaque_distance - 0.02);
	}
	if (t_exit <= t_enter + 0.01) {
		discard;
	}

	float step_length = (t_exit - t_enter) / float(max(max_steps, 1));
	float transmittance = 1.0;
	vec3 accumulated_light = vec3(0.0);
	vec3 wind = wind_direction * TIME * wind_speed;
	vec3 local_light_direction = normalize((world_to_local * vec4(normalize(light_direction), 0.0)).xyz);
	float threshold = 0.72 - cloud_coverage * 0.30;

	for (int i = 0; i < 64; i++) {
		if (i >= max_steps || transmittance < 0.035) {
			break;
		}

		float t = t_enter + (float(i) + 0.5) * step_length;
		vec3 p = ray_origin + ray_direction * t;
		vec3 uv = (p * 0.5 + 0.5) * noise_stretch + wind;
		vec3 base_uv = fract(uv);
		vec3 detail_uv = fract(uv * 2.35 + vec3(0.17, 0.39, 0.61));
		float broad = texture(base_noise, base_uv).r;
		float detail = texture(detail_noise, detail_uv).r;
		float density = shape_density(p, broad, detail);

		if (density > 0.015) {
			// A cheap occasional density probe approximates self-shadowing without
			// a second full ray march for every primary sample.
			float self_shadow = 1.0;
			if (i % 4 == 0) {
				vec3 light_p = p + local_light_direction * 0.075;
				vec3 light_uv = fract((light_p * 0.5 + 0.5) * noise_stretch + wind);
				float light_density = texture(base_noise, light_uv).r;
				self_shadow = 1.0 - clamp((light_density - threshold) * 0.60, 0.0, 0.27);
			}

			float height_light = smoothstep(-0.72, 0.68, p.y);
			float sun_light = max(dot(normalize(light_direction), vec3(0.0, 0.86, 0.50)), 0.0);
			float lighting = (0.53 + height_light * 0.30 + sun_light * 0.30) * self_shadow;
			vec3 sample_color = cloud_tint.rgb * lighting;

			float optical_depth = density * cloud_density * step_length * 0.012;
			float sample_alpha = 1.0 - exp(-optical_depth);
			accumulated_light += transmittance * sample_alpha * sample_color;
			transmittance *= 1.0 - sample_alpha;
		}
	}

	float opacity = 1.0 - transmittance;
	if (opacity < 0.004) {
		discard;
	}
	ALBEDO = accumulated_light / max(opacity, 0.001);
	ALPHA = clamp(opacity * cloud_tint.a, 0.0, 0.98);
}
