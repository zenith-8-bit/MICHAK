shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// Painterly matte terrain: chalk-brushed pigment, warm sunlit faces,
// cool violet shadows, hard-edged crest terminators, teal river.

uniform sampler2D detail_tex : filter_linear_mipmap, repeat_enable;

// World-space direction pointing TOWARD the sun (set from GDScript).
uniform vec3 sun_dir = vec3(-0.77, 0.56, 0.31);

uniform float detail_scale = 0.006;
uniform float brush_scale = 0.02;
uniform float color_patch_strength = 0.28;
uniform float paint_blend = 0.5;
uniform float strata_strength = 0.10;
uniform float strata_scale = 0.09;
uniform float chalk_strength = 0.24;
uniform float color_variation = 0.14;

uniform float warm_light_strength = 0.55;
uniform float cool_shadow_strength = 0.60;
uniform float terminator_hardness = 0.35;
uniform float term_lo = 0.08;
uniform float term_hi = 0.34;
uniform float shadow_lift = 0.03;

// Height shading: darker peaks, lighter mountain bodies.
uniform float height_scale = 130.0;
uniform float peak_start = 0.55;
uniform float peak_end = 0.82;
uniform float peak_darken = 0.60;
uniform float flank_lighten = 0.14;

// Distance dither so the streamed edge dissolves instead of popping.
uniform float fade_start = 100000.0;
uniform float fade_end = 100001.0;

varying vec3 world_pos;
varying vec3 world_normal;

// Palette is authored in sRGB; mesh COLOR is already linear.
vec3 lin(vec3 c) {
	return pow(c, vec3(2.2));
}

void vertex() {
	vec4 wp = MODEL_MATRIX * vec4(VERTEX, 1.0);
	world_pos = wp.xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	float dist = length(VERTEX);
	float fade = smoothstep(fade_start, fade_end, dist);
	if (fade > 0.001) {
		float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if (fade > dither) {
			discard;
		}
	}

	vec2 p = world_pos.xz;
	// Brush space: x runs along the top-left -> bottom-right diagonal.
	vec2 pr = vec2(p.x + p.y, p.y - p.x) * 0.70710678;

	float broad = texture(detail_tex, p * detail_scale + vec2(0.17, 0.31)).r;
	float broad2 = texture(detail_tex, p * detail_scale * 0.53 + vec2(0.63, 0.12)).r;

	// Long dragged strokes sweeping along the diagonal.
	float brush_a = texture(
		detail_tex,
		vec2(pr.x * brush_scale * 0.35, pr.y * brush_scale * 1.3)
		+ vec2(broad * 0.12, broad2 * 0.08)
	).r;
	float brush_b = texture(
		detail_tex,
		vec2(pr.x * brush_scale * 0.2, pr.y * brush_scale * 0.9)
		+ vec2(0.41, 0.73)
	).r;

	// Dry chalk grain for the dusty, matte look.
	float chalk = texture(
		detail_tex,
		vec2(pr.x * 0.05, pr.y * 0.22) + vec2(0.29, 0.57)
	).r;

	float pigment = broad * 0.48 + broad2 * 0.32 + brush_a * 0.13 + brush_b * 0.07;

	vec3 base = COLOR.rgb;

	vec3 rust  = lin(vec3(0.62, 0.25, 0.13));
	vec3 peach = lin(vec3(0.80, 0.50, 0.30));
	vec3 mauve = lin(vec3(0.36, 0.28, 0.42));
	vec3 ochre = lin(vec3(0.80, 0.58, 0.28));

	float warm_mask = smoothstep(0.34, 0.76, pigment);
	float cool_mask = 1.0 - smoothstep(0.32, 0.68, broad2 + broad * 0.25);

	vec3 warm = mix(rust, peach, smoothstep(0.32, 0.72, brush_a));
	warm = mix(warm, ochre, smoothstep(0.57, 0.84, brush_b) * 0.40);

	vec3 painted = mix(base, warm, warm_mask * color_patch_strength);
	painted = mix(painted, mauve, cool_mask * color_patch_strength * 0.45);

	painted *= 1.0 + (brush_a - 0.5) * color_variation;

	// Chalk dry-brush mostly on flat ground.
	float flatness = smoothstep(0.70, 0.95, world_normal.y);
	painted *= 1.0 + (chalk - 0.5) * chalk_strength * (0.4 + 0.6 * flatness);

	// Broken sediment bands.
	float strata_warp = (broad - 0.5) * 2.8 + (broad2 - 0.5) * 1.3;
	float band = smoothstep(0.50, 0.95, abs(sin(world_pos.y * strata_scale + strata_warp)));
	painted = mix(painted, painted * vec3(0.72, 0.75, 0.84), band * strata_strength);

	// Dual-temperature split: warm sunlit faces, cool violet shaded faces.
	float facing = dot(normalize(world_normal), normalize(sun_dir));
	float sunlit = smoothstep(0.12, 0.55, facing);
	vec3 warm_tint = vec3(1.14, 1.00, 0.80);
	vec3 cool_tint = vec3(0.74, 0.68, 0.96);
	float strength = mix(cool_shadow_strength, warm_light_strength, sunlit);
	painted *= mix(vec3(1.0), mix(cool_tint, warm_tint, sunlit), strength);

	// Mountain bodies a touch lighter and warmer, summits a touch darker.
	float hn = clamp(world_pos.y / max(height_scale, 1.0), 0.0, 1.0);
	float peak = smoothstep(peak_start, peak_end, hn);
	float flank = smoothstep(0.10, 0.38, hn) * (1.0 - peak);
	vec3 flank_tint = vec3(1.0 + flank_lighten, 1.0 + flank_lighten * 0.7, 1.0 + flank_lighten * 0.4);
	painted *= mix(vec3(1.0), flank_tint, flank);
	painted *= mix(vec3(1.0), vec3(0.66, 0.58, 0.72), peak * peak_darken);

	vec3 smoothed = mix(painted, mix(painted, base, 0.25), paint_blend * 0.20);

	// River: thin desaturated teal ribbon (vertex alpha carries the mask).
	float river = smoothstep(0.40, 0.56, COLOR.a + (brush_a - 0.5) * 0.12);
	vec3 water = mix(lin(vec3(0.10, 0.30, 0.36)), lin(vec3(0.45, 0.68, 0.70)), brush_b * 0.6);

	ALBEDO = max(mix(smoothed, water, river), vec3(0.0));
	EMISSION = water * river * 0.06;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);

	// Crisp terminator on crests blended with soft falloff elsewhere.
	float hard = smoothstep(term_lo, term_hi, ndl);
	float soft = smoothstep(-0.25, 0.85, ndl);
	float lit = mix(soft, hard, terminator_hardness);

	float shade = lit * (0.55 + 0.65 * clamp(ndl, 0.0, 1.0));

	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (shade + shadow_lift) / PI;
}
