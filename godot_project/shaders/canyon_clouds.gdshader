shader_type sky;
render_mode use_half_res_pass;

// Optional horizon layer inspired by the raymarched 3D-noise sky approach.
// Nearby clouds remain the separate spatial volumes in canyon_clouds.gdshader.
uniform sampler3D base_noise : filter_linear, repeat_enable;
uniform sampler3D detail_noise : filter_linear, repeat_enable;

uniform vec3 zenith_color : source_color = vec3(0.20, 0.34, 0.53);
uniform vec3 horizon_color : source_color = vec3(0.74, 0.60, 0.57);
uniform vec3 lower_sky_color : source_color = vec3(0.35, 0.36, 0.42);
uniform vec3 cloud_light_color : source_color = vec3(1.0, 0.86, 0.80);
uniform vec3 cloud_shadow_color : source_color = vec3(0.27, 0.30, 0.38);
uniform float cloud_coverage : hint_range(0.1, 1.0) = 0.52;
uniform float cloud_density : hint_range(0.1, 2.0) = 0.80;
uniform float cloud_noise_scale : hint_range(0.0005, 0.01) = 0.0032;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.30;
uniform vec2 wind_direction = vec2(1.0, 0.22);
uniform float wind_speed : hint_range(0.0, 0.01) = 0.0018;

const float PLANET_RADIUS = 6000.0;
const float CLOUD_BOTTOM_RADIUS = 6100.0;
const float CLOUD_TOP_RADIUS = 6280.0;

float ray_sphere_exit(vec3 origin, vec3 direction, float radius) {
	float b = dot(origin, direction);
	float c = dot(origin, origin) - radius * radius;
	float discriminant = b * b - c;
	if (discriminant < 0.0) {
		return -1.0;
	}
	return -b + sqrt(discriminant);
}

vec3 sky_background(vec3 direction) {
	if (direction.y >= 0.0) {
		return mix(horizon_color, zenith_color, pow(clamp(direction.y, 0.0, 1.0), 0.48));
	}
	return mix(horizon_color, lower_sky_color, clamp(-direction.y * 2.4, 0.0, 1.0));
}

vec3 render_distant_clouds(vec3 direction, vec3 background) {
	// Skip downward rays; the scene's terrain/mountains should occupy that view.
	if (direction.y <= 0.0) {
		return background;
	}

	vec3 origin = vec3(0.0, PLANET_RADIUS, 0.0);
	float t_start = ray_sphere_exit(origin, direction, CLOUD_BOTTOM_RADIUS);
	float t_end = ray_sphere_exit(origin, direction, CLOUD_TOP_RADIUS);
	if (t_start < 0.0 || t_end <= t_start) {
		return background;
	}

	const int STEPS = 44;
	float step_length = (t_end - t_start) / float(STEPS);
	float transmittance = 1.0;
	vec3 cloud_radiance = vec3(0.0);
	vec3 sun_direction = normalize(LIGHT0_DIRECTION);
	vec2 wind = wind_direction * TIME * wind_speed;

	for (int i = 0; i < STEPS; i++) {
		if (transmittance < 0.025) {
			break;
		}
		float distance_along_ray = t_start + (float(i) + 0.5) * step_length;
		vec3 p = origin + direction * distance_along_ray;
		float height_fraction = clamp((length(p) - CLOUD_BOTTOM_RADIUS) / (CLOUD_TOP_RADIUS - CLOUD_BOTTOM_RADIUS), 0.0, 1.0);

		vec3 noise_coord = p * cloud_noise_scale + vec3(wind.x, 0.0, wind.y);
		float broad = texture(base_noise, fract(noise_coord)).r;
		float detail = texture(detail_noise, fract(noise_coord * 2.2 + vec3(0.17, 0.41, 0.63))).r;
		float threshold = 0.72 - cloud_coverage * 0.30;
		float noise_fill = smoothstep(threshold - 0.12, threshold + 0.18, broad + (detail - 0.5) * detail_strength);
		float vertical_profile = smoothstep(0.02, 0.18, height_fraction) * (1.0 - smoothstep(0.68, 0.98, height_fraction));
		float density = noise_fill * vertical_profile;

		if (density > 0.012) {
			float top_light = smoothstep(0.0, 1.0, height_fraction);
			float sun_facing = max(dot(sun_direction, normalize(vec3(direction.x, 0.55, direction.z))), 0.0);
			float lighting = clamp(0.40 + top_light * 0.34 + sun_facing * 0.32, 0.0, 1.0);
			vec3 sample_color = mix(cloud_shadow_color, cloud_light_color, lighting);
			float optical_depth = density * cloud_density * step_length * 0.025;
			float sample_alpha = 1.0 - exp(-optical_depth);
			cloud_radiance += transmittance * sample_alpha * sample_color;
			transmittance *= 1.0 - sample_alpha;
		}
	}

	return cloud_radiance + background * transmittance;
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	vec3 background = sky_background(direction);
	if (AT_HALF_RES_PASS) {
		COLOR = render_distant_clouds(direction, background);
	} else {
		COLOR = HALF_RES_COLOR.rgb;
	}
	ALPHA = 1.0;
}
