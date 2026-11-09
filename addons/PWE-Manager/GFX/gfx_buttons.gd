@tool
extends Node3D

@export_group("PWE-Manager GFX")

# Echte Buttons mit @export_tool_button
# Das erste Argument ist der Text des Buttons, das zweite ein Icon-Name aus dem Editor-Theme

@export_tool_button("🟡Create ID_100", "Stop") # Gelbes/Oranges Icon durch "ActionPaste"
var btn_100 = _on_id_100

@export_tool_button("🟡Create ID_101", "Stop") # Rotes Icon durch "Stop"
var btn_101 = _on_id_101

@export_tool_button("🟡Create ID_102", "Stop")
var btn_102 = _on_id_102

@export_tool_button("🟡Create ID_110", "Stop")
var btn_110 = _on_id_110

@export_tool_button("🟡Create ID_120", "Stop")
var btn_120 = _on_id_120

@export_tool_button("🟡Create ID_121", "Stop")
var btn_121 = _on_id_121

@export_tool_button("🟡Create ID_122", "Stop")
var btn_122 = _on_id_122

@export_tool_button("🟡Create ID_123", "Stop")
var btn_123 = _on_id_123

@export_tool_button("🟡Create ID_124", "Stop")
var btn_124 = _on_id_124

@export_tool_button("🟡Create ID_125", "Stop")
var btn_125 = _on_id_125

@export_tool_button("🟡Create ID_130", "Stop")
var btn_130 = _on_id_130

@export_tool_button("🟡Create ID_140", "Stop")
var btn_140 = _on_id_140

@export_tool_button("🟡Create ID_150", "Stop")
var btn_150 = _on_id_150

@export_tool_button("🟡Create ID_151", "Stop")
var btn_151 = _on_id_151

@export_tool_button("🟡Create ID_152", "Stop")
var btn_152 = _on_id_152

@export_tool_button("🟡Create ID_160", "Stop")
var btn_160 = _on_id_160

@export_tool_button("🟡Create ID_170", "Stop")
var btn_170 = _on_id_170

@export_tool_button("🟡Create ID_180", "Stop")
var btn_180 = _on_id_180

@export_tool_button("🟡Create ID_190", "Stop")
var btn_190 = _on_id_190

@export_tool_button("🟡Create ID_200", "Stop")
var btn_200 = _on_id_200

@export_tool_button("🟡Create ID_210", "Stop")
var btn_210 = _on_id_210

@export_tool_button("🟡Create ID_211", "Stop")
var btn_211 = _on_id_211

@export_tool_button("🟡Create ID_220", "Stop")
var btn_220 = _on_id_220

@export_tool_button("🟡Create ID_230", "Stop")
var btn_230 = _on_id_230

@export_tool_button("Create All", "Stop")
var btn_all = _on_create_all

# --- Funktionen ---

func _on_id_100():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_100.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 100 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_100.gd nicht gefunden!")


func _on_id_101():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_101.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 100 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_101.gd nicht gefunden!")


func _on_id_102():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_101.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 101 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_101.gd nicht gefunden!")


func _on_id_110():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_110.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 110 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_101.gd nicht gefunden!")
		
		
func _on_id_120():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_120.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 120 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_101.gd nicht gefunden!")

func _on_id_121():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_121.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 121 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_121.gd nicht gefunden!")

func _on_id_122():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_122.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 122 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_122.gd nicht gefunden!")

func _on_id_123():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_123.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 123 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_123.gd nicht gefunden!")

func _on_id_124():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_124.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 124 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_124.gd nicht gefunden!")

func _on_id_125():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_125.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 125 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_125.gd nicht gefunden!")

func _on_id_130():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_130.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 130 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_130.gd nicht gefunden!")

func _on_id_140():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_140.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 140 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_140.gd nicht gefunden!")

func _on_id_150():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_150.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 150 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_150.gd nicht gefunden!")

func _on_id_151():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_151.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 151 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_151.gd nicht gefunden!")

func _on_id_152():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_152.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 152 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_152.gd nicht gefunden!")

func _on_id_160():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_160.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 160 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_160.gd nicht gefunden!")

func _on_id_170():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_170.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 170 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_170.gd nicht gefunden!")

func _on_id_180():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_180.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 180 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_180.gd nicht gefunden!")

func _on_id_190():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_190.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 190 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_190.gd nicht gefunden!")

func _on_id_200():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_200.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 200 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_200.gd nicht gefunden!")

func _on_id_210():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_210.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 210 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_210.gd nicht gefunden!")

func _on_id_211():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_211.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 211 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_211.gd nicht gefunden!")

func _on_id_220():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_220.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 220 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_220.gd nicht gefunden!")

func _on_id_230():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_230.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 230 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_230.gd nicht gefunden!")

func _on_id_120_backup3():
	var script_path = "res://addons/PWE-Manager/GFX/create_id_120_backup3.gd"
	if FileAccess.file_exists(script_path):
		var scr_res = load(script_path)
		var scr_ins = scr_res.new()
		if scr_ins.has_method("execute"):
			scr_ins.execute(self)
		print("ID 120 ausgeführt.")
		_report_sources()
	else:
		printerr("Fehler: res://create_id_120_backup3.gd nicht gefunden!")


func _on_create_all():
	_on_id_100()
	_on_id_101()
	print("Alle ID-Skripte (100 & 101) wurden ausgeführt.")

# Hinweise und geschriebene Dateien der Spieldaten-Quelle (gfx_sources.gd) melden, dann ihren
# Importer und den Text-Dekodierer freigeben (statisch gehalten blieben sie bis zum Beenden)
func _report_sources() -> void:
	var sources = load("res://addons/PWE-Manager/GFX/gfx_sources.gd")
	for w in sources.take_warnings():
		print("GFX: ", w)
	var written: Array = sources.take_written()
	if not written.is_empty() and Engine.has_singleton(&"EditorInterface"):
		var fs = Engine.get_singleton(&"EditorInterface").get_resource_filesystem()
		for f in written:
			fs.update_file(f)
	sources.release()
	load("res://addons/PWE-Manager/GFX/gfx_parser.gd").release_decoder()

func _pass():
	pass
