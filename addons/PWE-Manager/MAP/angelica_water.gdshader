// ====================================================
// Wasser einer Angelica-Map (A3DWaterArea, angelica_world.gd), wie ps\water_simple.txt:
// Fresnel (1 - cos)^4 mischt Tiefe (c2) und Oberfläche (c1), Alpha mit (1 - cos)^5 von 0.8 bis 1,
// dazu ein Glanzlicht der Sonne. Die Normalen kommen aus der Normalmap des Spiels (r = x,
// g = oben, b = z, wie in ps\water_cheap.txt), zwei Lagen gegeneinander verschoben.
// Gerechnet mit den Werten des Spiels (Gamma), erst am Ende für Godot umgerechnet (to_output).
// ====================================================
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D normal_map : filter_linear_mipmap, repeat_enable;
uniform vec3 deep_color = vec3(0.0, 0.25, 0.35);
uniform vec3 surface_color = vec3(0.2, 0.65, 0.65);
uniform float alpha_facing = 0.8;
uniform float alpha_grazing = 1.0;
// Wiederholungen der Normalmap je Meter, Lage 2 mal ripple_scale2
uniform float ripple_scale = 0.04;
uniform float ripple_scale2 = 1.7;
// Verschiebung der beiden Lagen in UV je Sekunde
uniform vec4 ripple_speed = vec4(0.012, 0.007, -0.009, 0.011);
// 0 = glatt, 1 = Normalmap voll
uniform float ripple_strength = 0.6;
// Richtung, in die das Sonnenlicht fällt
uniform vec3 sun_direction = vec3(-0.4, -0.8, -0.45);
uniform vec3 specular_color = vec3(1.0, 0.95, 0.85);
uniform float specular_power = 96.0;
uniform float specular_strength = 0.8;
uniform float brightness = 1.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Gamma-Werte -> Ausgabe: Forward+ / Mobile erwarten linear, Compatibility nimmt ALBEDO unverändert
vec3 to_output(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return c;
#else
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
#endif
}

void fragment() {
	vec2 uv = v_world.xz * ripple_scale;
	vec3 n1 = texture(normal_map, uv + TIME * ripple_speed.xy).rgb * 2.0 - 1.0;
	vec3 n2 = texture(normal_map, uv * ripple_scale2 + TIME * ripple_speed.zw).rgb * 2.0 - 1.0;
	vec3 n = normalize(mix(vec3(0.0, 1.0, 0.0), normalize(n1 + n2), ripple_strength));
	vec3 view = normalize(CAMERA_POSITION_WORLD - v_world);
	if (view.y < 0.0) {
		n.y = -n.y; // von unten
	}
	float c = clamp(dot(view, n), 0.0, 1.0);
	float f4 = pow(1.0 - c, 4.0);
	float f5 = f4 * (1.0 - c);
	vec3 col = mix(deep_color, surface_color, f4);
	vec3 r = reflect(-view, n);
	col += specular_color * pow(max(dot(r, -normalize(sun_direction)), 0.0), specular_power) * specular_strength;
	ALBEDO = to_output(clamp(col * brightness, 0.0, 1.0));
	ALPHA = mix(alpha_facing, alpha_grazing, f5);
}
