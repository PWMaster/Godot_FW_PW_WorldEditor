// ====================================================
// Gebäude einer Map (A3DLitModel, angelica_buildings.gd), gemeinsamer Teil von
// angelica_litmodel.gdshader (einseitig) und angelica_litmodel_2s.gdshader (2Sided).
// Wie ps\litmodelrender.txt: Farbe = Vertexfarbe (Tag, vorberechnetes Licht) x Textur x 2,
// Alpha = Textur-Alpha; Texturen mit Alpha mit Alpha-Test (84 / 255). Gerechnet mit den
// gespeicherten (Gamma-)Werten wie in D3D, erst am Ende für Godot umgerechnet. Unshaded.
// ====================================================

uniform sampler2D texture_albedo : filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;
uniform float alpha_ref = 0.3294;
uniform float brightness = 1.0;

// Forward+ / Mobile erwarten linear, Compatibility rechnet in sRGB
vec3 to_output(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return c;
#else
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
#endif
}

void fragment() {
	vec4 t = texture(texture_albedo, UV);
	ALBEDO = to_output(clamp(t.rgb * COLOR.rgb * 2.0 * brightness, 0.0, 1.0));
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_ref;
}
