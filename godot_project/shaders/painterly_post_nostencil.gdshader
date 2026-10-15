shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_test_disabled, depth_draw_never;

// Painterly post pass, drawn by a full-screen quad parented to the camera.
// Requires the Forward+ or Mobile renderer (uses the depth texture).
//
// Pipeline (all done in a perceptual, sqrt-encoded color space):
//   1. Anisotropic Kuwahara: brush strokes follow the local flow field
//   2. Depth + reconstructed-normal outlines, sepia ink, faded with distance
//   3. Luminance posterization + plum shadow / ochre highlight split-toning
//   4. Height fog toward dusty lavender
//   5. Paper grain and canvas bump
//
// Safety rules that keep screen noise from ever blowing up again:
//   - outlines come ONLY from depth and geometry, never from image luminance
//   - flow field is measured on a blurred (mip) copy of the image
//   - every stage has a bounded strength; effect_mix and debug_view exist
//   - NaN guard falls back to the untouched frame

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D paper_tex : filter_linear_mipmap, repeat_enable;

// ---- master ----
uniform float effect_mix : hint_range(0.0, 1.0) = 1.0;
// 0 final, 1 raw, 2 kuwahara only, 3 edges (R depth, G normal),
// 4 flow field, 5 fog amount, 6 depth
uniform int debug_view : hint_range(0, 6) = 0;

// ---- brush (anisotropic Kuwahara) ----
uniform int kuwahara_radius : hint_range(1, 4) = 3;
uniform float brush_size : hint_range(0.6, 4.0) = 1.5;
uniform float anisotropy : hint_range(0.0, 3.0) = 1.6;
uniform float flow_follow : hint_range(0.0, 1.0) = 0.8;
uniform float flow_blur_lod : hint_range(0.0, 4.0) = 2.0;
uniform float sharpness_q : hint_range(1.0, 16.0) = 6.0;
uniform float default_angle_deg = 45.0;   // stroke direction in flat areas

// ---- outlines ----
uniform float outline_strength : hint_range(0.0, 1.0) = 0.30;
uniform float depth_edge_lo = 0.02;
uniform float depth_edge_hi = 0.12;
uniform float normal_edge_lo = 0.08;
uniform float normal_edge_hi = 0.35;
uniform float edge_step_px : hint_range(1.0, 4.0) = 2.0;
uniform vec3 ink_color = vec3(0.60, 0.46, 0.52);
uniform float outline_fade_near = 260.0;
uniform float outline_fade_far = 900.0;
// Surface-angle outlines scribble over terrain facets; keep off unless wanted.
uniform float normal_outline_weight : hint_range(0.0, 1.0) = 0.0;

// ---- grading ----
uniform float poster_steps : hint_range(2.0, 12.0) = 5.0;
uniform float poster_strength : hint_range(0.0, 1.0) = 0.40;
uniform float poster_soft : hint_range(0.05, 0.5) = 0.28;
uniform float tone_strength : hint_range(0.0, 1.0) = 0.65;
uniform float saturation_boost : hint_range(0.8, 1.6) = 1.18;

// ---- comic halftone (Ben-Day dots) ----
// Dots grow in the shadows and mid-tones, stay out of highlights, the sky and
// the distant haze, so near rock, the plane and the mantas read as inked comic art.
uniform float halftone_strength : hint_range(0.0, 1.0) = 0.60;
uniform float halftone_cell_px : hint_range(3.0, 20.0) = 7.0;       // dot spacing in pixels
uniform float halftone_angle_deg = 45.0;
uniform float halftone_max_luma : hint_range(0.2, 1.0) = 0.70;      // no dots above this brightness
uniform vec3 halftone_ink = vec3(0.50, 0.32, 0.58);                  // multiplicative plum ink

// ---- height fog ----
// Illustration look: warm canyon in front, dusty blue-mauve haze far away.
uniform vec3 fog_color = vec3(0.62, 0.55, 0.74);   // perceptual-space dusty mauve-blue
uniform float fog_density = 0.0008;
uniform float fog_height_falloff = 0.004;
uniform float fog_base = 0.0;
uniform float fog_strength : hint_range(0.0, 1.0) = 0.62;
uniform float sky_haze : hint_range(0.0, 1.0) = 0.35;

// ---- paper ----
uniform float paper_strength : hint_range(0.0, 0.2) = 0.06;
uniform float paper_bump : hint_range(0.0, 0.2) = 0.04;
uniform float paper_scale = 6.0;

const vec3 LUMA = vec3(0.299, 0.587, 0.114);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// ---------- helpers ----------

vec3 fetch0(vec2 uv) {
	return sqrt(max(textureLod(screen_tex, uv, 0.0).rgb, vec3(0.0)));
}

float luma_lod(vec2 uv, float lod) {
	return dot(sqrt(max(textureLod(screen_tex, uv, lod).rgb, vec3(0.0))), LUMA);
}

float depth_raw(vec2 uv) {
	return textureLod(depth_tex, uv, 0.0).r;
}

vec3 vpos(vec2 uv, mat4 ip) {
	vec4 v = ip * vec4(uv * 2.0 - 1.0, depth_raw(uv), 1.0);
	return v.xyz / v.w;
}

// ---------- 1. flow field ----------

vec3 flow_field(vec2 uv, vec2 px) {
	vec2 e = px * exp2(flow_blur_lod) * 0.5;
	vec2 sp = e * 2.0;
	vec3 J = vec3(0.0);

	for (int k = 0; k < 5; k++) {
		vec2 u = uv;
		if (k == 1) { u += vec2(sp.x, 0.0); }
		if (k == 2) { u -= vec2(sp.x, 0.0); }
		if (k == 3) { u += vec2(0.0, sp.y); }
		if (k == 4) { u -= vec2(0.0, sp.y); }

		float gx = luma_lod(u + vec2(e.x, 0.0), flow_blur_lod) - luma_lod(u - vec2(e.x, 0.0), flow_blur_lod);
		float gy = luma_lod(u + vec2(0.0, e.y), flow_blur_lod) - luma_lod(u - vec2(0.0, e.y), flow_blur_lod);
		J += vec3(gx * gx, gx * gy, gy * gy);
	}
	J /= 5.0;

	float disc = sqrt(max((J.x - J.z) * (J.x - J.z) + 4.0 * J.y * J.y, 0.0));
	float l1 = 0.5 * (J.x + J.z + disc);
	float l2 = 0.5 * (J.x + J.z - disc);
	float coh = (l1 - l2) / (l1 + l2 + 1e-6);
	float mag = sqrt(max(l1, 0.0));
	float conf = smoothstep(0.004, 0.03, mag) * coh;

	// Strokes run along edges, i.e. perpendicular to the gradient.
	float phi = 0.5 * atan(2.0 * J.y, J.x - J.z) + 1.57079632;
	float d = radians(default_angle_deg);

	// Blend orientations in double-angle space so they wrap correctly.
	vec2 v = mix(
		vec2(cos(2.0 * d), sin(2.0 * d)),
		vec2(cos(2.0 * phi), sin(2.0 * phi)),
		conf * flow_follow
	);
	return vec3(0.5 * atan(v.y, v.x), conf, coh);
}

// ---------- 1b. anisotropic Kuwahara ----------

vec4 kuwahara_sector(vec2 uv, vec2 ax, vec2 ay, vec2 sg, int r) {
	vec3 s = vec3(0.0);
	vec3 s2 = vec3(0.0);
	float n = 0.0;

	for (int j = 0; j <= 4; j++) {
		for (int i = 0; i <= 4; i++) {
			if (i > r || j > r) { continue; }
			vec2 o = ax * float(i) * sg.x + ay * float(j) * sg.y;
			vec3 c = fetch0(uv + o);
			s += c;
			s2 += c * c;
			n += 1.0;
		}
	}

	vec3 m = s / n;
	vec3 v = abs(s2 / n - m * m);
	return vec4(m, v.r + v.g + v.b);
}

vec3 kuwahara(vec2 uv, vec2 px, float ang, float stretch) {
	float ca = cos(ang);
	float sa = sin(ang);
	vec2 ax = vec2(ca * px.x, sa * px.y) * brush_size * stretch;  // along flow
	vec2 ay = vec2(-sa * px.x, ca * px.y) * brush_size;           // across flow

	vec4 q0 = kuwahara_sector(uv, ax, ay, vec2(-1.0, -1.0), kuwahara_radius);
	vec4 q1 = kuwahara_sector(uv, ax, ay, vec2( 1.0, -1.0), kuwahara_radius);
	vec4 q2 = kuwahara_sector(uv, ax, ay, vec2( 1.0,  1.0), kuwahara_radius);
	vec4 q3 = kuwahara_sector(uv, ax, ay, vec2(-1.0,  1.0), kuwahara_radius);

	// Soft, variance-weighted blend: no hard seams between sectors.
	//
	// FIX (black silhouettes): the old weights were absolute, 1/(1+(255*sigma)^q).
	// On any high-contrast spot (plane/mantas against sky, ridge edges) all four
	// sectors get weights around 1e-9, and the old max(sum, 1e-6) denominator then
	// divided a ~1e-9 numerator by 1e-6 -> near-black pixels. Weights are now
	// RELATIVE to the calmest sector, so the best sector always has weight 1 and
	// the sum can never collapse.
	float vmin = min(min(q0.a, q1.a), min(q2.a, q3.a));
	float pw = sharpness_q * 0.5;
	float w0 = pow((vmin + 1e-5) / (q0.a + 1e-5), pw);
	float w1 = pow((vmin + 1e-5) / (q1.a + 1e-5), pw);
	float w2 = pow((vmin + 1e-5) / (q2.a + 1e-5), pw);
	float w3 = pow((vmin + 1e-5) / (q3.a + 1e-5), pw);

	return (q0.rgb * w0 + q1.rgb * w1 + q2.rgb * w2 + q3.rgb * w3)
		/ (w0 + w1 + w2 + w3);
}

// ---------- 2. outlines from depth + normals ----------

float inv_z(vec2 uv, mat4 ip) {
	if (depth_raw(uv) <= 0.0) { return 0.0; }
	return 1.0 / max(-vpos(uv, ip).z, 0.01);
}

// Second difference of inverse depth: zero on any flat slope, large only
// at real depth breaks. (A plain Sobel on depth lights up every grazing
// slope, which is the kind of false outline we want to avoid.)
float depth_edge(vec2 uv, vec2 px, mat4 ip) {
	vec2 s = px * edge_step_px;
	float c = inv_z(uv, ip);
	float l = inv_z(uv - vec2(s.x, 0.0), ip);
	float r = inv_z(uv + vec2(s.x, 0.0), ip);
	float u = inv_z(uv - vec2(0.0, s.y), ip);
	float d = inv_z(uv + vec2(0.0, s.y), ip);

	// No ink against the sky: the horizon should dissolve into haze.
	if (c <= 0.0 || l <= 0.0 || r <= 0.0 || u <= 0.0 || d <= 0.0) { return 0.0; }

	float lx = abs(l + r - 2.0 * c) / c;
	float ly = abs(u + d - 2.0 * c) / c;
	return smoothstep(depth_edge_lo, depth_edge_hi, max(lx, ly));
}

vec3 normal_at(vec2 uv, vec2 px, mat4 ip) {
	vec3 p = vpos(uv, ip);
	vec3 pr = vpos(uv + vec2(px.x, 0.0), ip);
	vec3 pu = vpos(uv + vec2(0.0, px.y), ip);
	return normalize(cross(pu - p, pr - p) + vec3(0.0, 0.0, 1e-8));
}

float normal_edge(vec2 uv, vec2 px, mat4 ip) {
	vec2 s = px * edge_step_px;
	if (depth_raw(uv) <= 0.0) { return 0.0; }

	vec2 uvl = uv - vec2(s.x, 0.0);
	vec2 uvr = uv + vec2(s.x, 0.0);
	vec2 uvu = uv - vec2(0.0, s.y);
	vec2 uvd = uv + vec2(0.0, s.y);
	if (depth_raw(uvl) <= 0.0 || depth_raw(uvr) <= 0.0 || depth_raw(uvu) <= 0.0 || depth_raw(uvd) <= 0.0) {
		return 0.0;
	}

	vec3 n0 = normal_at(uv, px, ip);
	float e = 0.0;
	e = max(e, 1.0 - dot(n0, normal_at(uvl, px, ip)));
	e = max(e, 1.0 - dot(n0, normal_at(uvr, px, ip)));
	e = max(e, 1.0 - dot(n0, normal_at(uvu, px, ip)));
	e = max(e, 1.0 - dot(n0, normal_at(uvd, px, ip)));
	return smoothstep(normal_edge_lo, normal_edge_hi, e);
}

// ---------- 3. grading ----------

float poster_l(float l) {
	float x = l * poster_steps;
	float f = floor(x);
	return (f + smoothstep(0.5 - poster_soft, 0.5 + poster_soft, x - f)) / poster_steps;
}

vec3 grade(vec3 c) {
	float L = dot(c, LUMA);

	// Tonal block-in with soft steps (hue preserved).
	if (L < 1.0) {
		float ratio = clamp(poster_l(L) / max(L, 0.03), 0.6, 1.6);
		c = mix(c, c * ratio, poster_strength);
		L = dot(c, LUMA);
	}

	// Dual tone: cool desaturated plum shadows, warm ochre highlights.
	float sh = 1.0 - smoothstep(0.08, 0.45, L);
	float hi = smoothstep(0.45, 0.90, L);
	vec3 shadow_c = mix(vec3(L), c, 0.70) * vec3(0.86, 0.74, 1.14);
	vec3 high_c = c * vec3(1.12, 1.00, 0.78);
	c = mix(c, shadow_c, sh * tone_strength);
	c = mix(c, high_c, hi * tone_strength);

	// Richer terracotta / violet like the painting.
	float L2 = dot(c, LUMA);
	c = mix(vec3(L2), c, saturation_boost);
	return c;
}

// ---------- 3b. halftone dots ----------
// Returns 0..1 ink coverage for a rotated dot grid. Dot AREA follows darkness.
float halftone(vec2 frag_px, float L) {
	float a = radians(halftone_angle_deg);
	mat2 rot = mat2(vec2(cos(a), -sin(a)), vec2(sin(a), cos(a)));
	vec2 p = (rot * frag_px) / halftone_cell_px;
	vec2 g = fract(p) - 0.5;
	float d = length(g);

	float cover = clamp((halftone_max_luma - L) / halftone_max_luma, 0.0, 1.0);
	float r = sqrt(cover) * 0.70710678;          // radius so area ~ coverage
	float aa = 1.0 / halftone_cell_px;           // ~1 pixel in cell units
	return 1.0 - smoothstep(r - aa, r + aa, d);
}

// ---------- 4. height fog ----------

float height_fog(vec3 vp, bool sky, mat4 inv_view) {
	vec3 cam = inv_view[3].xyz;
	vec3 wp = (inv_view * vec4(vp, 1.0)).xyz;
	vec3 wdir = normalize((inv_view * vec4(vp, 0.0)).xyz);

	if (sky) {
		// Haze hugs the horizon and thins toward the zenith.
		return (1.0 - smoothstep(0.0, 0.35, wdir.y)) * sky_haze;
	}

	float dist = length(vp);
	float k = fog_height_falloff;
	float base = fog_density * exp(-k * max(cam.y - fog_base, 0.0)) * dist;
	float t = clamp(k * (wp.y - cam.y), -8.0, 8.0);
	float shape = 1.0;
	if (abs(t) > 1e-3) { shape = (1.0 - exp(-t)) / t; }
	return clamp(1.0 - exp(-base * shape), 0.0, 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = 1.0 / VIEWPORT_SIZE;
	mat4 ip = INV_PROJECTION_MATRIX;
	mat4 iv = INV_VIEW_MATRIX;

	vec3 raw = fetch0(uv);
	vec3 raw_lin = raw * raw;

	// 1. brush strokes
	vec3 flow = flow_field(uv, px);
	vec3 col = kuwahara(uv, px, flow.x, 1.0 + anisotropy * flow.y);
	vec3 kuw = col;

	// 2. outlines (depth + normals only)
	float d_raw = depth_raw(uv);
	bool sky = d_raw <= 0.0;
	vec3 vp = vpos(uv, ip);
	float dist = length(vp);
	if (sky) { dist = 4000.0; }

	float de = depth_edge(uv, px, ip);
	float ne = 0.0;
	if (normal_outline_weight > 0.001) { ne = normal_edge(uv, px, ip); }

	float edge = max(de, ne * normal_outline_weight);
	edge *= 1.0 - smoothstep(outline_fade_near, outline_fade_far, dist);
	edge *= outline_strength;
	col = mix(col, col * ink_color, edge);

	// 3. posterize + split-tone
	col = grade(col);

	// 3b. comic halftone dots (not on sky, faded out by distance haze)
	float fog = height_fog(vp, sky, iv);
	if (!sky && halftone_strength > 0.001) {
		float dots = halftone(FRAGCOORD.xy, dot(col, LUMA));
		dots *= 1.0 - clamp(fog * fog_strength * 1.5, 0.0, 1.0);
		col = mix(col, col * halftone_ink, dots * halftone_strength);
	}

	// 4. height fog
	col = mix(col, fog_color, fog * fog_strength);

	// 5. paper grain + canvas bump (small, bounded)
	vec2 suv = uv * vec2(VIEWPORT_SIZE.x / VIEWPORT_SIZE.y, 1.0);
	float p1 = texture(paper_tex, suv * paper_scale).r;
	float p2 = texture(paper_tex, suv * paper_scale * 4.0 + vec2(0.37, 0.61)).r;
	float p2b = texture(paper_tex, suv * paper_scale * 4.0 + vec2(0.37, 0.61) + vec2(0.004, 0.004)).r;
	float paper = p1 * 0.6 + p2 * 0.4;
	col *= 1.0 + (paper - 0.5) * paper_strength * 2.0;
	col *= 1.0 + clamp((p2 - p2b) * 20.0, -1.0, 1.0) * paper_bump;

	col = clamp(col, vec3(0.0), vec3(2.0));
	vec3 out_lin = col * col;

	// NaN guard: if anything went wrong, show the untouched frame.
	if (isnan(out_lin.r) || isnan(out_lin.g) || isnan(out_lin.b)) {
		out_lin = raw_lin;
	}

	vec3 result = mix(raw_lin, out_lin, effect_mix);

	// Debug views (no early return: fragment() must not use `return`).
	if (debug_view == 1) {
		result = raw_lin;
	} else if (debug_view == 2) {
		result = kuw * kuw;
	} else if (debug_view == 3) {
		result = vec3(de, ne, 0.0);
	} else if (debug_view == 4) {
		result = vec3(0.5 + 0.5 * cos(2.0 * flow.x), 0.5 + 0.5 * sin(2.0 * flow.x), flow.y);
	} else if (debug_view == 5) {
		result = vec3(fog);
	} else if (debug_view == 6) {
		result = vec3(clamp(dist / 1500.0, 0.0, 1.0));
	}

	ALBEDO = result;
}
