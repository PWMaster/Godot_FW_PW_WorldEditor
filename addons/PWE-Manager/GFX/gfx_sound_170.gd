@tool
extends Node3D

# ====================================================
# Laufzeit-Treiber für GFXELEMENTID 170 (A3DGFXSound / GFXSOUNDIMP), angelegt von create_id_170.gd.
# GFXSOUNDIMP::TickSound, solange das Element aktiv ist:
#   - erster Tick eines GFX-Durchlaufs (Play): Zufallsdatei aus Sounds (nie dreimal hintereinander
#     dieselbe), Lautstärke VolMin..VolMax (0..100), Tonhöhe PitchMin..PitchMax in Halbtönen
#     (Abspieltempo 2^(p/12)), dann Play(IsLoop)
#   - jede Wiederholung (RepeatCount -> ResumeLoop): dieselbe Datei startet neu
#   - Elementende (IsFinished): StopSound, neuer GFX-Durchlauf: der alte Sound wird freigegeben
#   - Position = kp.m_vPos (gfx_keypoint_eval.gd), die Zeit läuft wie in den ID_100-Shadern
# 3D wie DirectSound3D: volle Lautstärke bis MinDist, danach MinDist / Entfernung,
# ab MaxDist zum Zuhörer stumm (CheckDist).
# Im Editor läuft der Sound nur mit Play_In_Editor im Takt der GFX-Zeit, sonst über die
# Play-Buttons (2D-Vorschau, immer hörbar). Die Player sind interne Child-Nodes und werden
# nicht mitgespeichert.
# ====================================================

const KP = preload("gfx_keypoint_eval.gd")

const SILENT_DB = -80.0
const PLAY_FILE_PREFIX = "play_file_"

@export_group("Time_Settings")
@export var Time_Manual: bool = false
## Manuelle Zeit in ms (entspricht dem Shader-Parameter "Time")
@export var Time_Ms: float = 0.0
@export var GlobalLoopTime: float = 3000.0
@export var LocalStartTime: float = 0.0
@export var LocalTotalTime: float = 3000.0
@export var Is_Endless: bool = false
@export var RepeatCount: int = 1
@export var RepeatDelay: float = 0.0

@export_group("Sound")
## Path-Einträge aus der .gfx (relativ zu Sfx\), nur zur Info
@export var Sound_Paths: PackedStringArray = PackedStringArray()
## Geladene Sounds (Reihenfolge wie Sound_Paths), beim Start wird zufällig gewählt
@export var Sounds: Array[AudioStream] = []:
	set(value):
		Sounds = value
		_loop_cache.clear()
		update_configuration_warnings()
		notify_property_list_changed()
## IsLoop: Datei wiederholen, bis das Element endet
@export var Loop: bool = false
## VolMin / VolMax: zufällige Lautstärke 0..100 (linear)
@export_range(0, 100) var Volume_Min: int = 100
@export_range(0, 100) var Volume_Max: int = 100
## PitchMin / PitchMax: zufällige Tonhöhe in Halbtönen
@export_range(-12.0, 12.0, 0.01) var Pitch_Min: float = 0.0
@export_range(-12.0, 12.0, 0.01) var Pitch_Max: float = 0.0
## Force2D: ohne Raumklang, überall gleich laut
@export var Force_2D: bool = false
## MinDist: bis zu dieser Entfernung volle Lautstärke, danach MinDist / Entfernung
@export var Min_Dist: float = 12.0
## MaxDist: ab dieser Entfernung zum Zuhörer ist der Sound stumm
@export var Max_Dist: float = 50.0
@export var Bus: StringName = &"Master"
## Audio-Event (Angelica 2.2, GFXSOUNDIMP22), nur zur Info
@export var Audio_Event: String = ""

@export_group("KeyPoints")
@export var keypoints: Array = []

@export_group("Preview")
## Im Editor im Takt der GFX-Zeit abspielen (im Spiel immer), räumlich zur Editor-Kamera
@export var Play_In_Editor: bool = false
@export_tool_button("Play", "Play") var btn_play = preview_play
@export_tool_button("Stop", "Stop") var btn_stop = preview_stop

var _player_3d: AudioStreamPlayer3D = null
var _player_2d: AudioStreamPlayer = null
var _player_preview: AudioStreamPlayer = null
var _active_player: Node = null # Player des Sounds, der im Takt der GFX-Zeit läuft
var _cycle = -1 # GFX-Durchlauf des aktuellen Sounds
var _repeat = -1 # zuletzt gestartete Wiederholung
var _pick = {} # {index, volume, pitch} des aktuellen GFX-Durchlaufs
var _last_time = -INF
var _last_index = -1 # CheckSoundFileChange
var _same_count = 0
var _loop_cache = {}


func _ready() -> void:
	_ensure_players()

func _process(_delta: float) -> void:
	apply_time(_clock_ms())
	_update_distance()

func _clock_ms() -> float:
	return KP.clock_ms(Time_Manual, Time_Ms)

func _get_configuration_warnings() -> PackedStringArray:
	var missing = PackedStringArray()
	for i in range(Sound_Paths.size()):
		if i >= Sounds.size() or Sounds[i] == null:
			missing.append(Sound_Paths[i])
	if _valid_indices().is_empty():
		return PackedStringArray(["Kein Sound geladen: sfx\\<Path> nicht in den Spieldaten (Leiste ECM-GFX-MAP: Spieldaten-Ordner)" + ("" if missing.is_empty() else ": " + ", ".join(missing))])
	if not missing.is_empty():
		return PackedStringArray(["Sounds fehlen (werden bei der Zufallsauswahl übersprungen): " + ", ".join(missing)])
	return PackedStringArray()


# ====================================================
# PLAY-BUTTONS IM INSPEKTOR
# ====================================================
# Ab zwei Dateien zusätzlich ein Button je Datei
func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = []
	if Sounds.size() < 2:
		return props
	props.append({"name": "Einzelne Dateien", "type": TYPE_NIL, "usage": PROPERTY_USAGE_SUBGROUP, "hint_string": PLAY_FILE_PREFIX})
	for i in range(Sounds.size()):
		var label = "%d: %s" % [i + 1, _file_label(i)]
		props.append({
			"name": PLAY_FILE_PREFIX + str(i + 1),
			"type": TYPE_CALLABLE,
			"hint": PROPERTY_HINT_TOOL_BUTTON,
			"hint_string": label.replace(",", " ") + ",Play",
			"usage": PROPERTY_USAGE_EDITOR,
		})
	return props

func _get(property: StringName):
	var p = str(property)
	if p.begins_with(PLAY_FILE_PREFIX):
		var index = p.trim_prefix(PLAY_FILE_PREFIX).to_int() - 1
		if index >= 0 and index < Sounds.size():
			return preview_file.bind(index)
	return null

func _file_label(index: int) -> String:
	if index < Sound_Paths.size() and Sound_Paths[index] != "":
		return Sound_Paths[index].replace("\\", "/").get_file()
	if Sounds[index] != null and Sounds[index].resource_path != "":
		return Sounds[index].resource_path.get_file()
	return "Sound"

# Wie ein GFX-Start (Zufallsdatei, -lautstärke, -tonhöhe), als 2D-Vorschau
func preview_play() -> void:
	_preview(_new_pick())

func preview_file(index: int) -> void:
	if index < 0 or index >= Sounds.size() or Sounds[index] == null:
		push_warning("GFX Sound: Datei " + str(index + 1) + " ist nicht geladen")
		return
	_preview(_make_pick(index))

func preview_stop() -> void:
	if _player_preview != null:
		_player_preview.stop()

func _preview(pick: Dictionary) -> void:
	if pick.is_empty():
		push_warning("GFX Sound: kein Sound geladen")
		return
	_ensure_players()
	_configure(_player_preview, pick)
	_player_preview.play()


# ====================================================
# ZUSTAND ZUR GLOBALEN ZEIT (A3DGFXSound::TickAnimation / GFXSOUNDIMP::TickSound)
# ====================================================
func apply_time(active_time: float) -> void:
	var t = element_time(active_time)
	var active = Is_Endless or (t >= LocalStartTime and t <= LocalTotalTime)
	if active and not keypoints.is_empty():
		# m_pBuf->SetPosition(GetParentTM() * kp.m_vPos)
		position = evaluate(maxf(0.0, t - LocalStartTime))["pos"]

	if Engine.is_editor_hint() and not Play_In_Editor:
		if _cycle != -1:
			_stop_sound()
			_cycle = -1
			_repeat = -1
		return
	_sync_sound(active_time, play_state(active_time))

# Element-Zeit in ms (identisch zur Zeit-Synchronisation der ID_100-Shader)
func element_time(active_time: float) -> float:
	return KP.element_time(active_time, GlobalLoopTime, LocalStartTime, LocalTotalTime, RepeatCount, RepeatDelay)

# span_ms = Zeit seit StartTime. Liefert {pos, dir, color, scale, rad}.
func evaluate(span_ms: float) -> Dictionary:
	return KP.evaluate(keypoints, span_ms)

# Wiedergabe-Zustand zur globalen Zeit (gleiche Zeitlogik wie KP.element_time):
#   cycle    = GFX-Durchlauf (GlobalLoopTime), Wechsel = A3DGFXSound::Stop + Play
#   repeat   = Wiederholung des Elements, Wechsel = ResumeLoop
#   active   = Element tickt (nach StartTime, nicht in der RepeatDelay-Pause)
#   finished = alle Wiederholungen vorbei (IsFinished -> StopSound)
func play_state(active_time: float) -> Dictionary:
	var st = {"cycle": 0, "repeat": -1, "active": false, "finished": false}
	var f_repeat = float(RepeatCount)
	var t_global = active_time
	if f_repeat >= 0.0:
		var loop_time = maxf(0.001, GlobalLoopTime)
		st["cycle"] = int(floor(active_time / loop_time))
		t_global = fmod(active_time, loop_time)
	var t_since_start = t_global - LocalStartTime
	if t_since_start < 0.0:
		return st
	if Is_Endless or LocalTotalTime <= 0.0:
		# Unendlicher KeyPoint: kein ResumeLoop, der Sound läuft bis zum Ende des GFX
		st["repeat"] = 0
		st["active"] = true
		return st
	var active_duration = maxf(0.001, LocalTotalTime - LocalStartTime)
	var full_duration = active_duration + maxf(0.0, RepeatDelay)
	var rep = int(floor(t_since_start / full_duration))
	# RepeatCount 0 läuft wie in den Shadern einmal durch
	if f_repeat >= 0.0 and rep >= maxi(1, RepeatCount):
		st["finished"] = true
		return st
	st["repeat"] = rep
	st["active"] = fmod(t_since_start, full_duration) <= active_duration
	return st

func _sync_sound(active_time: float, st: Dictionary) -> void:
	# Neuer GFX-Durchlauf oder Zeit zurückgesetzt: Stop (Sound freigeben) + Play (neue Auswahl)
	if st["cycle"] != _cycle or active_time < _last_time:
		_stop_sound()
		_cycle = st["cycle"]
		_repeat = -1
		_pick = {}
	_last_time = active_time

	if st["finished"]:
		_stop_sound()
		return
	# In der RepeatDelay-Pause tickt das Element nicht: der Sound läuft weiter, startet aber nicht
	if st["active"] and st["repeat"] != _repeat:
		_repeat = st["repeat"]
		if _pick.is_empty():
			_pick = _new_pick() # ChangeSoundFile + UpdateSoundChange
		_start_sound(_pick)

func _start_sound(pick: Dictionary) -> void:
	_stop_sound()
	if pick.is_empty():
		return
	_ensure_players()
	var player: Node = _player_2d if Force_2D else _player_3d
	_configure(player, pick)
	player.play()
	_active_player = player
	_update_distance()

func _stop_sound() -> void:
	if _active_player != null:
		_active_player.stop()
		_active_player = null


# ====================================================
# AUSWAHL UND PLAYER-EINSTELLUNGEN (GFXSOUNDIMP::ChangeSoundFile / UpdateSoundChange)
# ====================================================
func _new_pick() -> Dictionary:
	return _make_pick(_rand_sound_index())

func _make_pick(index: int) -> Dictionary:
	if index < 0:
		return {}
	# GetRandVolume (ganzzahlig, inklusive) / GetRandPitch
	var vol_lo = mini(Volume_Min, Volume_Max)
	var vol_hi = maxi(Volume_Min, Volume_Max)
	var volume = vol_lo if vol_lo == vol_hi else randi_range(vol_lo, vol_hi)
	var pitch = Pitch_Min if Pitch_Min == Pitch_Max else randf_range(minf(Pitch_Min, Pitch_Max), maxf(Pitch_Min, Pitch_Max))
	return {"index": index, "volume": volume, "pitch": pitch}

# GetRandSfxFilePath + CheckSoundFileChange: Zufallsdatei, beim dritten Mal in Folge die nächste andere
func _rand_sound_index() -> int:
	var valid = _valid_indices()
	if valid.is_empty():
		return -1
	var index: int = valid[randi() % valid.size()]
	if valid.size() > 1:
		if index == _last_index:
			_same_count += 1
			if _same_count >= 2:
				for i in valid:
					if i != index:
						index = i
						break
				_last_index = index
				_same_count = 0
		else:
			_last_index = index
			_same_count = 0
	return index

func _valid_indices() -> Array:
	var valid = []
	for i in range(Sounds.size()):
		if Sounds[i] != null:
			valid.append(i)
	return valid

func _configure(player: Node, pick: Dictionary) -> void:
	player.stream = _stream_for(Sounds[pick["index"]], Loop)
	player.volume_db = _volume_db(pick["volume"])
	player.pitch_scale = pow(2.0, pick["pitch"] / 12.0) # SetPlaySpeed(2^(Pitch / 12))
	player.bus = Bus
	if player is AudioStreamPlayer3D:
		player.unit_size = maxf(0.01, Min_Dist) # SetMinDistance
		player.max_db = player.volume_db # innerhalb MinDist volle (gewählte) Lautstärke

# SetRelativeVolume(0..100), linear
func _volume_db(volume: int) -> float:
	if volume <= 0:
		return SILENT_DB
	return maxf(SILENT_DB, linear_to_db(volume / 100.0))

# Play(IsLoop) gilt unabhängig von den Import-Einstellungen der Datei
func _stream_for(stream: AudioStream, loop: bool) -> AudioStream:
	var key = str(stream.get_instance_id()) + ("_loop" if loop else "_once")
	if _loop_cache.has(key):
		return _loop_cache[key]
	var result = stream
	if stream is AudioStreamWAV:
		var wav: AudioStreamWAV = stream
		if (wav.loop_mode != AudioStreamWAV.LOOP_DISABLED) != loop:
			var copy: AudioStreamWAV = wav.duplicate()
			if loop:
				copy.loop_mode = AudioStreamWAV.LOOP_FORWARD
				copy.loop_begin = 0
				copy.loop_end = int(round(wav.get_length() * wav.mix_rate))
			else:
				copy.loop_mode = AudioStreamWAV.LOOP_DISABLED
			result = copy
	elif "loop" in stream and bool(stream.get("loop")) != loop:
		# AudioStreamOggVorbis / AudioStreamMP3
		var copy = stream.duplicate()
		copy.set("loop", loop)
		if "loop_offset" in copy:
			copy.set("loop_offset", 0.0)
		result = copy
	_loop_cache[key] = result
	return result

func _ensure_players() -> void:
	if _player_3d != null:
		return
	_player_3d = AudioStreamPlayer3D.new()
	_player_3d.name = "Player3D"
	_player_3d.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_player_3d.max_distance = 0.0 # MaxDist schneidet _update_distance ab (ohne Godots lineares Ausblenden)
	_player_3d.attenuation_filter_cutoff_hz = 20500.0 # kein Tiefpass mit der Entfernung
	_player_3d.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	add_child(_player_3d, false, Node.INTERNAL_MODE_BACK)
	_player_2d = AudioStreamPlayer.new()
	_player_2d.name = "Player2D"
	add_child(_player_2d, false, Node.INTERNAL_MODE_BACK)
	_player_preview = AudioStreamPlayer.new()
	_player_preview.name = "PlayerPreview"
	add_child(_player_preview, false, Node.INTERNAL_MODE_BACK)


# ====================================================
# CHECKDIST: AB MAXDIST ZUM ZUHÖRER STUMM
# ====================================================
func _update_distance() -> void:
	if _active_player == null or _active_player != _player_3d:
		return
	var listener = _listener_position()
	var muted = listener != null and Max_Dist > 0.0 and global_position.distance_to(listener) >= Max_Dist
	var limit = SILENT_DB if muted else _player_3d.volume_db
	if _player_3d.max_db != limit:
		_player_3d.max_db = limit

# Zuhörer wie bei AudioStreamPlayer3D: AudioListener3D oder aktive Kamera,
# im Editor die Kamera des ersten 3D-Viewports
func _listener_position() -> Variant:
	var vp: Viewport = get_viewport()
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		vp = Engine.get_singleton(&"EditorInterface").get_editor_viewport_3d(0)
	if vp == null:
		return null
	var listener = vp.get_audio_listener_3d()
	if listener != null:
		return listener.global_position
	var cam = vp.get_camera_3d()
	if cam != null:
		return cam.global_position
	return null
