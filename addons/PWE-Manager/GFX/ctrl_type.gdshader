shader_type spatial;
// Sorgt dafür, dass Schatten und unnötige Lichtberechnungen für ein unsichtbares Objekt deaktiviert werden
render_mode blend_mix, shadows_disabled, unshaded;

// ==========================================
// CtrlType_100
// ==========================================
group_uniforms CtrlType_100;
uniform int   c100_CtrlType = 100;
uniform float c100_StartTime = 0.0;
uniform float c100_EndTime = -1.0;
uniform vec3  c100_Dir;
uniform float c100_Vel;
uniform float c100_Acc;

// ==========================================
// CtrlType_101
// ==========================================
group_uniforms CtrlType_101;
uniform int   c101_CtrlType = 101;
uniform float c101_StartTime = 0.0;
uniform float c101_EndTime = -1.0;
uniform float c101_Vel;
uniform float c101_Acc;

// ==========================================
// CtrlType_102
// ==========================================
group_uniforms CtrlType_102;
uniform int   c102_CtrlType = 102;
uniform float c102_StartTime = 0.0;
uniform float c102_EndTime = -1.0;
uniform vec3  c102_Pos = vec3(0.0);
uniform vec3  c102_Axis = vec3(0.0, 1.0, 0.0);
uniform float c102_Vel = 6.981317;
uniform float c102_Acc = 0.0;

group_uniforms; 

// ==========================================
// Hilfsfunktion: Rotationsmatrix erzeugen
// (Rotiert um eine beliebige Achse mit einem bestimmten Winkel)
// ==========================================
mat3 construct_rotation_matrix(vec3 axis, float angle) {
    axis = normalize(axis);
    float s = sin(angle);
    float c = cos(angle);
    float oc = 1.0 - c;
    
    return mat3(
        vec3(oc * axis.x * axis.x + c,           oc * axis.x * axis.y - axis.z * s,  oc * axis.z * axis.x + axis.y * s),
        vec3(oc * axis.x * axis.y + axis.z * s,  oc * axis.y * axis.y + c,           oc * axis.y * axis.z - axis.x * s),
        vec3(oc * axis.z * axis.x - axis.y * s,  oc * axis.y * axis.z + axis.x * s,  oc * axis.z * axis.z + c)
    );
}


void vertex() {
    // Nur ausführen, wenn wir uns im CtrlType_102 befinden
    if (c102_CtrlType == 102) {
        
        // Zeiterfassung (TIME ist die globale Shader-Zeit in Godot)
        float t = TIME - c102_StartTime;
        
        // Startet erst, wenn die Startzeit erreicht ist
        if (t >= 0.0) {
            
            // Looping Mechanismus: Wenn EndTime größer als 0 ist, fängt 't' danach wieder bei 0 an
            if (c102_EndTime > 0.0) {
                t = mod(t, c102_EndTime);
            }
            
            // Verhindern, dass Vektoren der Länge 0 genutzt werden (verursacht Shader-Crashes)
            if (length(c102_Axis) > 0.001) {
                
                // Berechnung des aktuellen Winkels (s = v*t + 0.5*a*t^2)
                float current_angle = (c102_Vel * t) + (0.5 * c102_Acc * t * t);
                
                // Rotationsmatrix aus der Achse und dem Winkel generieren
                mat3 rot_matrix = construct_rotation_matrix(c102_Axis, current_angle);
                
                // 1. Objekt zum Pivot-Punkt (Pos) verschieben
                vec3 local_pos = VERTEX - c102_Pos;
                
                // 2. Objekt drehen
                local_pos = rot_matrix * local_pos;
                
                // 3. Offset wieder hinzufügen
                VERTEX = local_pos + c102_Pos;
            }
        }
    }
}

void fragment() {
    // Macht das Objekt völig transparent (unsichtbar)
    ALPHA = 0.0;
}