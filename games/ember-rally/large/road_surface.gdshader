shader_type spatial;
render_mode diffuse_burley, specular_disabled;

// Opaque local ground overlay. UV.x is signed road distance; UV.y is the
// clearing's ash blend. No ALPHA, transparency sorting, decal, or extra ruts.
// Grass sampling/tint is deliberately identical to ground_surface.gdshader.
uniform sampler2D grass_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D road_texture : source_color, filter_linear_mipmap, repeat_disable;
varying vec2 road_world_xz;

void vertex() {
	road_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

vec3 grass_paint(vec2 at) {
	vec2 mirrored_uv = vec2(1.0) - abs(mod(at, vec2(2.0)) - vec2(1.0));
	return textureGrad(grass_texture, mirrored_uv, dFdx(at), dFdy(at)).rgb;
}

vec3 road_paint(vec2 at) {
	vec2 mirrored_uv = vec2(1.0) - abs(mod(at, vec2(2.0)) - vec2(1.0));
	return textureGrad(road_texture, mirrored_uv, dFdx(at), dFdy(at)).rgb;
}

vec2 alternate(vec2 uv) {
	return vec2(uv.x * 0.80 - uv.y * 0.60, uv.x * 0.60 + uv.y * 0.80) * 0.877 + vec2(0.373, 0.619);
}

void fragment() {
	vec2 world = road_world_xz;
	vec2 grass_uv = world / 32.0;
	vec3 grass = mix(grass_paint(grass_uv), grass_paint(alternate(grass_uv)), 0.18);
	float grass_luma = dot(grass, vec3(0.2126, 0.7152, 0.0722));
	grass = mix(grass, vec3(grass_luma), 0.12);
	vec2 orchard_delta = world - vec2(94.0, 88.0);
	float charred = exp(-dot(orchard_delta, orchard_delta) / 130.0) * 0.22;
	float north = smoothstep(100.0, 180.0, world.x) * (1.0 - smoothstep(10.0, 55.0, world.y)) * 0.12;
	vec3 region_tint = vec3(1.0 - charred - north * 0.5, 1.0 - charred, 1.0 - charred + north * 0.4);
	grass *= vec3(0.96, 1.0, 0.94) * region_tint;

	vec2 road_uv = world / 28.0;
	vec3 dirt = mix(road_paint(road_uv), road_paint(alternate(road_uv)), 0.18);
	float dirt_luma = dot(dirt, vec3(0.2126, 0.7152, 0.0722));
	float ash = clamp(UV.y, 0.0, 1.0);
	dirt = mix(dirt, vec3(dirt_luma), ash * 0.65);
	dirt *= mix(vec3(0.99, 0.98, 0.95), vec3(0.87, 0.89, 0.91), ash);
	// The authored paint also gently wears the edge. All exterior pixels use
	// exactly the existing grass color, preventing a bright/dark outline.
	float edge = UV.x + (dirt_luma - 0.45) * 0.14;
	float coverage = 1.0 - smoothstep(-0.22, 0.32, edge);
	ALBEDO = mix(grass, dirt, coverage);
	ROUGHNESS = 1.0;
}
