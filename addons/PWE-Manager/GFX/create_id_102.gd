@tool
extends EditorScript

const SHADER_CODE = """
shader_type spatial;

render_mode cull_disabled, unshaded, depth_draw_opaque;

uniform sampler2D custom_texture : source_color;

// SegLife: Steuert NUR die Länge des Segments (25 = sehr kurz, 10000 = extrem lang)
uniform int SegLife : hint_range(25, 10000, 25) = 1000;

// Speed_Vel: Steuert die Geschwindigkeit (und Richtung). 
// 1.0 = normale Geschwindigkeit, 2.0 = doppelt so schnell, -1.0 = rückwärts
uniform float Speed_Vel = 1.0;

uniform float FadeLength : hint_range(0.01, 0.5) = 0.15; 

// 5 Kontrollpunkte der Bézier-Kurve
uniform vec3 point_0 = vec3(-2.0, 0.0, 0.0);
uniform vec3 point_1 = vec3(-1.0, 1.0, -1.0);
uniform vec3 point_2 = vec3(0.0, 0.0, -2.0);
uniform vec3 point_3 = vec3(1.0, -1.0, -1.0);
uniform vec3 point_4 = vec3(2.0, 0.0, 0.0);

vec3 get_curve_position(float t) {
    float u = 1.0 - t;
    float tt = t * t;
    float uu = u * u;
    float uuu = uu * u;
    float ttt = tt * t;
    
    vec3 p = uuu * u * point_0; 
    p += 4.0 * uuu * t * point_1;
    p += 6.0 * uu * tt * point_2;
    p += 4.0 * u * ttt * point_3;
    p += ttt * t * point_4; 
    
    return p;
}

void vertex() {
    vec3 curve_pos = get_curve_position(UV.x);
    
    vec3 pos_next = get_curve_position(clamp(UV.x + 0.01, 0.0, 1.0));
    vec3 pos_prev = get_curve_position(clamp(UV.x - 0.01, 0.0, 1.0));
    vec3 tangent = normalize(pos_next - pos_prev);
    
    vec3 up = vec3(0.0, 1.0, 0.0);
    if (abs(tangent.y) > 0.99) {
        up = vec3(0.0, 0.0, 1.0);
    }
    
    vec3 right = normalize(cross(tangent, up));
    vec3 local_up = normalize(cross(right, tangent));
    
    VERTEX = curve_pos + (local_up * VERTEX.y) + (right * VERTEX.z);
}

void fragment() {
    // 1. Umrechnung von SegLife in die UV-Länge
    // 1000 = 1.0 (Die Textur ist exakt so lang wie die gesamte Kurve)
    float trail_length = float(SegLife) / 1000.0;
    
    // Sicherheitscheck: Fade darf nicht länger sein als das halbe Segment
    float actual_fade = min(FadeLength, trail_length / 2.0);
    
    // 2. Unabhängige Zeitberechnung (Loop von 0.0 bis 1.0 basierend auf Speed_Vel)
    // Wenn Speed_Vel negativ ist, drehen wir die Richtung um
    float time_cycle = fract(TIME * Speed_Vel);
    if (time_cycle < 0.0) {
        time_cycle += 1.0;
    }
    
    // 3. Kopf und Ende des Trails berechnen
    float start_pos = -actual_fade - trail_length;
    float end_pos = 1.0 + actual_fade + trail_length;
    
    float head = mix(start_pos, end_pos, time_cycle);
    float tail = head - trail_length;
    
    // 4. Fade-Maske für weiche Kanten
    float mask = smoothstep(tail, tail + actual_fade, UV.x) * smoothstep(head, head - actual_fade, UV.x);
    
    // 5. DAS BILD STAUCHEN / STRECKEN
    float mapped_u = (UV.x - tail) / trail_length;
    mapped_u = clamp(mapped_u, 0.0, 1.0);
    
    // 6. Textur auslesen und anwenden
    vec4 tex_color = texture(custom_texture, vec2(mapped_u, UV.y));
    ALBEDO = tex_color.rgb;
    ALPHA = tex_color.a * mask;
}
"""

func _run():
	var scene = get_scene()
	if not scene:
		print("Fehler: Bitte öffne zuerst eine 3D-Szene!")
		return
		
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "SpeedTrailPlane"
	
	mesh_instance.extra_cull_margin = 1000.0
	
	var plane_mesh = PlaneMesh.new()
	plane_mesh.size = Vector2(4.0, 1.0) 
	plane_mesh.subdivide_width = 50 
	plane_mesh.subdivide_depth = 2
	mesh_instance.mesh = plane_mesh
	
	var shader = Shader.new()
	shader.code = SHADER_CODE
	
	var material = ShaderMaterial.new()
	material.shader = shader
	
	mesh_instance.set_surface_override_material(0, material)
	scene.add_child(mesh_instance)
	mesh_instance.owner = scene
	
	print("Erfolg! Der Trail nutzt nun SegLife für die Länge und Speed_Vel für die Geschwindigkeit.")
