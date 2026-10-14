// Painterly canyon terrain: vertex colour + brush-like detail noise + soft cel lighting.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D detail_tex : filter_linear_mipmap, repeat_enable;
uniform float detail_scale = 0.018;
uniform float steps = 4.0;
uniform float cel_mix = 0.55;
uniform float ambient_lift = 0.06;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float d1 = texture(detail_tex, wpos.xz * detail_scale).r;
	float d2 = texture(detail_tex, wpos.xz * detail_scale * 4.3 + vec2(0.37)).r;
	vec3 col = COLOR.rgb * (0.78 + 0.44 * d1) * (0.90 + 0.20 * d2);
	ALBEDO = col;
	ROUGHNESS = 1.0;
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float stepped = floor(ndl * steps + 0.5) / steps;
	float k = mix(ndl, stepped, cel_mix);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (k + ambient_lift) / PI;
}
