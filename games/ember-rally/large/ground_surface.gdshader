shader_type spatial;
render_mode diffuse_burley, specular_disabled;

// Only the flat ground/dirt/ash meshes use this shader. Sprite and wall filters
// stay untouched. World coordinates deliberately ignore every streaming chunk.
uniform sampler2D surface_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform float texture_world_size = 32.0;
uniform vec4 surface_tint : source_color = vec4(1.0);
uniform float secondary_weight : hint_range(0.0, 0.4) = 0.18;
uniform float desaturation : hint_range(0.0, 1.0) = 0.0;
uniform bool regional_ground = false;
varying vec2 ground_world_xz;

void vertex() {
	ground_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

vec3 mirrored_paint(vec2 at) {
	// Mirror instead of wrapping different source edges against one another.
	// This is C0-continuous even if the hand-painted source is not seamless.
	vec2 mirrored_uv = vec2(1.0) - abs(mod(at, vec2(2.0)) - vec2(1.0));
	// Explicit unwrapped derivatives keep mip selection steady at mirror turns.
	return textureGrad(surface_texture, mirrored_uv, dFdx(at), dFdy(at)).rgb;
}

void fragment() {
	vec2 world = ground_world_xz;
	vec2 uv = world / texture_world_size;
	vec3 painted = mirrored_paint(uv);
	// A quiet rotated layer breaks reflected motifs. No generated grit/noise,
	// screen-space filtering, normal-map noise, or time-dependent surface motion.
	vec2 alternate_uv = vec2(uv.x * 0.80 - uv.y * 0.60, uv.x * 0.60 + uv.y * 0.80) * 0.877 + vec2(0.373, 0.619);
	painted = mix(painted, mirrored_paint(alternate_uv), secondary_weight);
	float luminance = dot(painted, vec3(0.2126, 0.7152, 0.0722));
	painted = mix(painted, vec3(luminance), desaturation);
	vec3 region_tint = vec3(1.0);
	if (regional_ground) {
		vec2 orchard_delta = world - vec2(94.0, 88.0);
		float charred = exp(-dot(orchard_delta, orchard_delta) / 130.0) * 0.22;
		float north = smoothstep(100.0, 180.0, world.x) * (1.0 - smoothstep(10.0, 55.0, world.y)) * 0.12;
		region_tint = vec3(1.0 - charred - north * 0.5, 1.0 - charred, 1.0 - charred + north * 0.4);
	}
	ALBEDO = painted * surface_tint.rgb * region_tint;
	ROUGHNESS = 1.0;
}
