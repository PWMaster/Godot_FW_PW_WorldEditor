// ====================================================
// Terrain einer Angelica-Map (A3DTerrain2, angelica_terrain.gd), je Maskenbereich ein Material.
// Wie ps\t2_3layer_batch_14.txt: Ebene 0 voll, jede weitere mit ihrer Maske darübergeblendet
// (lrp), dann mal Lightmap x 2 (mul_x2). Gerechnet wie in D3D mit den gespeicherten (Gamma-)
// Werten, erst am Ende für Godot umgerechnet (to_output). Die Lightmap enthält das Licht: unshaded.
// Textur-Koordinaten je Ebene (A3DTerrain2Block::FillVertexBuffer, ApplyLayerTexture):
//   Achse 0: (z, y - Mindesthöhe)  1: (x, z)  2: (x, y - Mindesthöhe), mal UV-Skalierung
// Masken und Lightmap über die UVs des Maskenbereichs (0..1).
// ====================================================
shader_type spatial;
render_mode unshaded, cull_back;

const int MAX_LAYERS = 16;

// Bodentexturen der Map, Ebene layer_index[i] im Array
uniform sampler2DArray layer_textures : filter_linear_mipmap_anisotropic, repeat_enable;
// Masken der Ebenen 1 .. layer_count - 1 dieses Bereichs
uniform sampler2DArray layer_masks : filter_linear_mipmap, repeat_disable;
uniform sampler2D lightmap : filter_linear_mipmap, repeat_disable, hint_default_white;
uniform int layer_count = 1;
uniform int layer_index[MAX_LAYERS];
// x, y = UV-Skalierung, z = Projektionsachse
uniform vec4 layer_uv[MAX_LAYERS];
// Mindesthöhe der Teilkarte (TRN2FILESUBTRN::fMinHei)
uniform float min_height = 0.0;
uniform bool use_lightmap = true;
uniform float brightness = 1.0;

varying vec3 v_pos;

void vertex() {
	v_pos = VERTEX;
}

// Gamma-Werte (wie in D3D gerechnet) -> Ausgabe: Forward+ / Mobile erwarten linear,
// Compatibility rechnet in sRGB und nimmt ALBEDO unverändert
vec3 to_output(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return c;
#else
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
#endif
}

void fragment() {
	vec3 col = vec3(0.0);
	for (int i = 0; i < MAX_LAYERS; i++) {
		if (i >= layer_count) {
			break;
		}
		vec4 p = layer_uv[i];
		vec2 uv = p.z < 0.5 ? vec2(v_pos.z, v_pos.y - min_height) : (p.z < 1.5 ? v_pos.xz : vec2(v_pos.x, v_pos.y - min_height));
		vec3 c = texture(layer_textures, vec3(uv * p.xy, float(layer_index[i]))).rgb;
		float m = i == 0 ? 1.0 : texture(layer_masks, vec3(UV, float(i - 1))).r;
		col = mix(col, c, m);
	}
	vec3 light = use_lightmap ? texture(lightmap, UV).rgb * 2.0 : vec3(1.0);
	ALBEDO = to_output(clamp(col * light * brightness, 0.0, 1.0));
}
