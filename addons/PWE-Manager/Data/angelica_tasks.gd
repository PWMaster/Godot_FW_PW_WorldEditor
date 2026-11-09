@tool
extends RefCounted

# ====================================================
# Quests des Spiels lesen (data\tasks.data + tasks.data1 ... N, ATaskTemplMan / ATaskTempl).
#   tasks.data   Inhaltsverzeichnis: Kennung 0x03958276, Version, Anzahl Quests, Anzahl Teildateien,
#                Export-Zeit, danach Prüfsummen (MD5) der Teildateien
#   tasks.dataN  Kennung 0x02003304, Anzahl, Offset je Quest, dann die Quests (LoadBinary):
#     fester Teil (ATaskTemplFixedData, roh), variable Teile (Unterschrift, Zeitplan, Vorbedingungs-,
#     Start- und Zielgegenstände, Team, gesuchte Monster, Texte fester Länge), Belohnungen (Erfolg /
#     Misserfolg, je nach Verhältnis / Gegenständen / Anzahl / Abgabe gestuft), 5 Texte (Beschreibung,
#     Ja, Nein, Tribut, Rundspruch), 5 Gespräche (talk_proc wie in elements.data: Quest geben,
#     Bedingungen nicht erfüllt, Gegenstand geben, während der Quest, Belohnung), Unteraufgaben
#     (Anzahl + Quests gleichen Aufbaus).
# Strukturen und Einfügestellen je Version: angelica_tasks_schema.json (aus TaskTempl.h v181, pack 1,
# Zeiger 8 Bytes). Version 184 (Client) liest alle 11.572 Quests bis aufs Byte.
# Jede Quest: Dictionary mit den Feldern unten, "subs" (Unteraufgaben), "parent" (ID oder 0),
# "_raw" (fester Teil, für field()).
# Texte: UTF-16, Platzhalter wie &name& / $name und Farbcodes ^RRGGBB bleiben stehen.
# Gelesen über angelica_files.gd (files, entpackt oder aus den .pck), ohne files über FileAccess.
# locate(files, Sprache): <Sprache>/data/tasks.data, sonst data/tasks.data, sonst eine andere Sprache.
# unsupported(Quest): gesetzte Vorbedingungen, die das Spiel noch nicht prüft (UNSUPPORTED).
# npc_positions(files, Sprache): data\task_npc.data (ATaskTemplMan::LoadNPCInfoFromPack) -> {NPC-Vorlage:
# [Welt, Vector3]}: Kopf (Paketgröße, Zeitstempel, Version 2 (u16), Anzahl (u16)), je NPC 16 Bytes
# (NPC_INFO: Vorlage, Welt, x, y, z als short, 2 Füllbytes) - Ziele der Autoroute zu Quest-NPCs.
# Speicher: load_all() hält alle Quests (Client v184: ~260 MB); index_all() merkt sich nur, wo jede
# Quest steht (Teildatei, Nummer, oberste Quest), get_task() liest sie dann bei Bedarf samt ihrer
# Unteraufgaben (die zuletzt gelesene Teildatei bleibt zwischengespeichert).
# ====================================================

const SCHEMA_FILE = "angelica_tasks_schema.json"
const INFO_MAGIC = 0x03958276
const PACK_MAGIC = 0x02003304
const NAME_CHARS = 30 # MAX_TASK_NAME_SIZE
const METHOD_CHARS = 64 # MAX_TASK_METHOD_TEXT_SIZE
const METHODS = {0: "Unteraufgaben", 1: "Monster töten", 2: "Gegenstände sammeln", 3: "NPC ansprechen",
	4: "Ort erreichen", 5: "Warten", 6: "Frage beantworten", 7: "Minispiel", 8: "NPC beschützen",
	9: "NPC begleiten", 10: "Titel", 11: "Quest mehrmals erfüllen", 12: "Abbauen", 13: "Gegenstand benutzen",
	14: "Spieler besiegen", 15: "Erfolge", 16: "Emote", 17: "Gegenstände abgeben", 18: "Arena gewinnen",
	19: "Arena verlieren", 20: "Arena bestreiten"}
const SCALE_EXTRA = {"ratio": 128, "items": 132, "count": 128, "submit": 32} # Bytes nach der Stufenzahl
const LANGUAGES = ["Deu", "Eng", "Franz"]
# Vorbedingungen, die das Spiel (Godot-Server und -Client) noch nicht prüft: mit einem Wert ungleich
# 0 / false ist eine Quest der obersten Ebene vorerst nicht vergebbar (CheckPrerequisite des gs).
# Nicht dabei: m_i64RegionMask (Server-Regionen, CCheckRegionMask: unser Server gilt für alle) und
# m_bTeamwork (sperrt nur mit m_bRcvByTeam, CCheckTeamTask)
const UNSUPPORTED = ["m_ulTimetable", "m_bBirthday", "m_bDelvInZone", "m_ulPremItems",
	"m_ulPremTitleCount", "m_ulPremise_Deposit", "m_lPremise_Reputation", "m_nPremise_Vigour", "m_nPremise_Vitality",
	"m_nPremise_InteractionPoints", "m_lPremise_Contribution", "m_nPremise_FamContrib", "m_ulPremise_FactionMoney",
	"m_ulPremise_FacCredit", "m_ulPremise_AchievementCount", "m_ulPremise_AchievementPoint", "m_ulPremise_Period",
	"m_ulPremise_Faction", "m_bPremise_Master", "m_bPremise_Spouse", "m_ulPremise_Cotask_Cnt", "m_ulPremFinishTaskCount",
	"m_ulPremGlobalCount", "m_lSkillLev", "m_ulSpecialAward", "m_bPremise_GM", "m_bPremise_CallPet", "m_bRcvByTeam",
	"m_bMarriage", "m_bSharedByFamily", "m_bLuaTask", "m_bInFamily", "m_bFamilyHeader", "m_ulPremSkillCnt",
	"m_ulPremBuffCnt", "m_ulPremAccompCnt", "m_iBindMoney", "m_bDiscoverMap", "m_iFlyLevel", "m_iBelief",
	"m_iMinGodLevel", "m_iMinEvilLevel", "m_cVipLevel", "m_ulConsumeScore", "m_iServerType", "m_iMarriage",
	"m_bCreateDungeon", "m_bEnterDungeon", "m_bDeathTrig", "m_bEmotionTrig", "m_bPursueTradeTask", "m_bRaidTeam",
	"m_ulChangedRace", "m_nPremBattleScoreMin"]

var path = ""
var version = 0
var count = 0
var pack_count = 0
var export_time = 0
var tasks: Dictionary = {} # ID -> Quest (alle Ebenen)
var top: Array = [] # IDs der obersten Ebene
var errors: Array = [] # Quests, die nicht genau aufgingen
var index = {} # ID -> [Teildatei, Nr. darin, ID der obersten Quest] (index_all)
var _schema: Dictionary = {}
var _fx: Dictionary = {} # Feldname -> [Offset, Art, Anzahl, Größe] (fester Teil, v181)
var _ad: Dictionary = {} # dasselbe für AWARD_DATA
var _sizes: Dictionary = {} # Strukturname -> Größe
var _v: Dictionary = {} # Version: fixed_size, fixed_steps, award_size, award_steps
var _files = null # angelica_files.gd oder null
var _indexing: Array = [] # während index_all: [Teildatei, Nr., oberste ID]
var _pack_cache = [0, PackedByteArray()] # zuletzt gelesene Teildatei (get_task)


# tasks.data der Sprache in den Spieldaten -> Pfad oder ""
static func locate(files, lang: String = "") -> String:
	var order = [lang] if lang != "" else []
	order.append("")
	for l in LANGUAGES:
		if not l in order:
			order.append(l)
	for l in order:
		var bases = ["data"] if l == "" else [l + "/data", "resources/" + l + "/data"]
		for base in bases:
			var p: String = files.resolve(base + "/tasks.data")
			if p != "":
				return p
	return ""


# tasks.data (Inhaltsverzeichnis) öffnen -> "" oder Fehlertext; load_all() liest die Quests
func open(info_path: String, files = null) -> String:
	path = info_path
	_files = files
	tasks = {}
	top = []
	errors = []
	var b = _bytes(info_path)
	if b.size() < 20 or b.decode_u32(0) != INFO_MAGIC:
		return info_path + ": keine tasks.data"
	version = b.decode_u32(4)
	count = b.decode_u32(8)
	pack_count = b.decode_u32(12)
	export_time = b.decode_s32(16)
	if not _load_schema():
		return SCHEMA_FILE + " fehlt"
	_v = _schema["versions"].get(str(version), {})
	if _v.is_empty():
		return "Quest-Version %d unbekannt (bekannt: %s)" % [version, ", ".join(_schema["versions"].keys())]
	return ""

# Alle Teildateien lesen -> Anzahl der Quests der obersten Ebene
func load_all() -> int:
	for k in pack_count:
		load_pack(k + 1)
	return top.size()

# Teildatei tasks.dataN lesen -> Anzahl Quests darin (-1 = nicht lesbar)
func load_pack(n: int) -> int:
	var b = _bytes(path + str(n))
	if b.size() < 8 or b.decode_u32(0) != PACK_MAGIC:
		errors.append("%s%d nicht lesbar" % [path.get_file(), n])
		return -1
	var c = b.decode_u32(4)
	for i in c:
		var start = b.decode_u32(8 + 4 * i)
		var end = b.decode_u32(8 + 4 * (i + 1)) if i + 1 < c else b.size()
		var at = [start]
		var t = _task(b, at, 0)
		if at[0] != end:
			errors.append("Quest %d (%s%d Nr. %d): %d Bytes Abweichung" % [t.get("id", 0), path.get_file(), n, i, end - at[0]])
		top.append(t["id"])
	return c

static func npc_positions(files, lang: String = "") -> Dictionary:
	var out = {}
	for base in ([lang + "/data", "resources/" + lang + "/data"] if lang != "" else []) + ["data"]:
		var p: String = files.resolve(base + "/task_npc.data")
		if p == "":
			continue
		var b: PackedByteArray = files.get_bytes(p)
		if b.size() < 12 or b.decode_u32(0) != b.size() or b.decode_u16(8) != 2:
			continue
		var n = b.decode_u16(10)
		for i in n:
			var o = 12 + i * 16
			if o + 16 > b.size():
				break
			out[b.decode_u32(o)] = [b.decode_s32(o + 4), Vector3(b.decode_s16(o + 8), b.decode_s16(o + 10), b.decode_s16(o + 12))]
		return out
	return out

# Felder aus UNSUPPORTED, die bei der Quest gesetzt sind
func unsupported(q: Dictionary) -> Array:
	var out = []
	for fname in UNSUPPORTED:
		var v = field(q, fname)
		if (v is bool and v) or ((v is int or v is float) and v != 0):
			out.append(fname)
	return out

# Alle Teildateien einmal lesen, aber nur merken, wo jede Quest steht -> Anzahl der obersten Ebene
func index_all() -> int:
	index = {}
	top = []
	for k in pack_count:
		var b = _bytes(path + str(k + 1))
		if b.size() < 8 or b.decode_u32(0) != PACK_MAGIC:
			errors.append("%s%d nicht lesbar" % [path.get_file(), k + 1])
			continue
		for i in b.decode_u32(4):
			_indexing = [k + 1, i, 0]
			var t = _task(b, [b.decode_u32(8 + 4 * i)], 0)
			top.append(t["id"])
	_indexing = []
	return top.size()

func _bytes(p: String) -> PackedByteArray:
	return _files.get_bytes(p) if _files != null else FileAccess.get_file_as_bytes(p)

func get_task(id: int) -> Dictionary:
	if tasks.has(id) or not index.has(id):
		return tasks.get(id, {})
	var at: Array = index[id]
	if _pack_cache[0] != at[0]:
		_pack_cache = [at[0], _bytes(path + str(at[0]))]
	var b: PackedByteArray = _pack_cache[1]
	if b.size() >= 8 and b.decode_u32(0) == PACK_MAGIC and at[1] < b.decode_u32(4):
		_task(b, [b.decode_u32(8 + 4 * at[1])], 0)
	return tasks.get(id, {})

# Beliebiges Feld des festen Teils (Name wie TaskTempl.h, z.B. "m_bCanGiveUp"); Arrays als Array
func field(t: Dictionary, name: String):
	return _field(t.get("_raw", PackedByteArray()), name)


# ====================================================
# LESEN
# ====================================================
func _task(b: PackedByteArray, at: Array, parent: int) -> Dictionary:
	var fs: int = _v["fixed_size"]
	var raw = b.slice(at[0], at[0] + fs)
	at[0] += fs
	if not _indexing.is_empty() and parent == 0:
		_indexing[2] = _u(raw, "m_ID")
	var t = {
		"id": _u(raw, "m_ID"), "name": _wstr(raw, _off("m_szName"), NAME_CHARS), "parent": parent,
		"type": _u(raw, "m_ulType"), "auto_deliver": _u(raw, "m_bAutoDeliver") != 0,
		"can_give_up": _u(raw, "m_bCanGiveUp") != 0, "can_redo": _u(raw, "m_bCanRedo") != 0,
		"delv_npc": _u(raw, "m_ulDelvNPC"), "award_npc": _u(raw, "m_ulAwardNPC"),
		"delv_world": _u(raw, "m_ulDelvWorld"), "level_min": _u(raw, "m_ulPremise_Lev_Min"),
		"level_max": _u(raw, "m_ulPremise_Lev_Max"), "gender": _u(raw, "m_ulGender"),
		"races": _list(raw, "m_ulRaces", "m_Races"), "occupations": _list(raw, "m_ulOccupations", "m_Occupations"),
		"premise_tasks": _list(raw, "m_ulPremise_Task_Count", "m_ulPremise_Tasks"),
		"method": _u(raw, "m_enumMethod"), "finish_type": _u(raw, "m_enumFinishType"),
		"time_limit": _u(raw, "m_ulTimeLimit"),
	}
	# variable Teile (LoadFixedDataFromBinFile)
	if _u(raw, "m_bHasSign") != 0:
		at[0] += 2 * NAME_CHARS
	at[0] += _u(raw, "m_ulTimetable") * 2 * _sizes["task_tm"]
	t["premise_items"] = _items(b, at, _u(raw, "m_ulPremItems"))
	at[0] += _u(raw, "m_ulPremTitleCount") * 2
	t["given_items"] = _items(b, at, _u(raw, "m_ulGivenItems"))
	if _u(raw, "m_bTeamwork") != 0:
		at[0] += _u(raw, "m_ulTeamMemsWanted") * _sizes["TEAM_MEM_WANTED"]
	var mons = []
	for i in _u(raw, "m_ulMonsterWanted"):
		var p: int = at[0]
		mons.append({"id": b.decode_u32(p), "num": b.decode_u32(p + 4), "drop_item": b.decode_u32(p + 8),
			"drop_count": b.decode_u32(p + 12), "drop_common": b.decode_u8(p + 16) != 0, "drop_prob": b.decode_float(p + 17)})
		at[0] += _sizes["MONSTER_WANTED"]
	t["monsters"] = mons
	if _u(raw, "m_bHasGatherMonster") != 0:
		at[0] += 2 * NAME_CHARS
	if _u(raw, "m_bHasFinishTaskTimes") != 0:
		at[0] += 2 * METHOD_CHARS
	t["items"] = _items(b, at, _u(raw, "m_ulItemsWanted"))
	at[0] += 2 * _u(raw, "m_ulWelcomeWords")
	t["submit_items"] = _items(b, at, _u(raw, "m_ulItemsSubmitWanted"))
	# Belohnungen
	t["award"] = _award(b, at)
	t["award_fail"] = _award(b, at)
	for kind in ["ratio", "items", "count", "submit"]:
		for k in 2:
			var n = b.decode_u32(at[0])
			at[0] += 4 + SCALE_EXTRA[kind]
			for i in n:
				_award(b, at)
	# Texte
	var texts = []
	for i in 5:
		var n = b.decode_u32(at[0])
		texts.append(_wstr(b, at[0] + 4, n))
		at[0] += 4 + 2 * n
	t["description"] = texts[0]
	t["ok_text"] = texts[1]
	t["no_text"] = texts[2]
	t["tribute"] = texts[3]
	t["broadcast"] = texts[4]
	# Gespräche: Quest geben, Bedingungen fehlen, Gegenstand geben, während der Quest, Belohnung
	var talks = []
	for i in 5:
		talks.append(_talk(b, at))
	t["talk_deliver"] = talks[0]
	t["talk_unqualified"] = talks[1]
	t["talk_deliver_item"] = talks[2]
	t["talk_execute"] = talks[3]
	t["talk_award"] = talks[4]
	var subs = []
	var nsub = b.decode_s32(at[0])
	at[0] += 4
	for i in nsub:
		subs.append(_task(b, at, t["id"]))
	t["subs"] = subs
	t["_raw"] = raw
	if _indexing.is_empty():
		tasks[t["id"]] = t
	else:
		index[t["id"]] = [_indexing[0], _indexing[1], _indexing[2] if parent != 0 else t["id"]]
	return t

func _award(b: PackedByteArray, at: Array) -> Dictionary:
	var size: int = _v["award_size"]
	var raw = b.slice(at[0], at[0] + size)
	at[0] += size
	var a = {"gold": _ua(raw, "m_ulGoldNum"), "exp": _ua(raw, "m_ulExp"), "sp": _ua(raw, "m_ulSP"),
		"reputation": _ua(raw, "m_ulReputation"), "new_task": _ua(raw, "m_ulNewTask"), "items": []}
	for i in _ua(raw, "m_ulCandItems"):
		var group = {"random": b.decode_u8(at[0]) != 0, "items": []}
		at[0] += 1
		var n = _read_u32(b, at)
		group["items"] = _items(b, at, n)
		a["items"].append(group)
	at[0] += 9 * _ua(raw, "m_ulChangeKeyCnt") + 4 * _ua(raw, "m_ulDisplayKeyCnt")
	if _ua(raw, "m_bAwardSpecifyRole") != 0 and _ua(raw, "m_ulRoleSelected") != 0:
		a["role"] = _award(b, at)
	return a

func _read_u32(b: PackedByteArray, at: Array) -> int:
	var v = b.decode_u32(at[0])
	at[0] += 4
	return v

# ITEM_WANTED: ID, gewöhnlich (bool), Anzahl ...
func _items(b: PackedByteArray, at: Array, n: int) -> Array:
	var out = []
	for i in n:
		var p: int = at[0]
		out.append({"id": b.decode_u32(p), "common": b.decode_u8(p + 4) != 0, "num": b.decode_u32(p + 5),
			"prob": b.decode_float(p + 14)})
		at[0] += _sizes["ITEM_WANTED"]
	return out

# talk_proc (wie elements.data, Optionen mit param_addon)
func _talk(b: PackedByteArray, at: Array) -> Dictionary:
	var p: int = at[0]
	var t = {"id": b.decode_u32(p), "title": _wstr(b, p + 4, 64), "windows": []}
	var nw = b.decode_s32(p + 132)
	p += 136
	for w in nw:
		var tl = b.decode_s32(p + 8)
		var win = {"id": b.decode_u32(p), "parent": b.decode_u32(p + 4), "text": _wstr(b, p + 12, tl), "options": []}
		p += 12 + 2 * tl
		var no = b.decode_s32(p)
		p += 4
		for o in no:
			win["options"].append({"id": b.decode_u32(p), "text": _wstr(b, p + 4, 64), "param": b.decode_u32(p + 132)})
			p += 140
		t["windows"].append(win)
	at[0] = p
	return t


# ====================================================
# FELDER
# ====================================================
func _load_schema() -> bool:
	if not _schema.is_empty():
		return true
	var p = (get_script() as Script).resource_path.get_base_dir().path_join(SCHEMA_FILE)
	var d = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
	if not d is Dictionary:
		return false
	_schema = d
	for v in _schema["versions"].values():
		v["fixed_size"] = int(v["fixed_size"])
		v["award_size"] = int(v["award_size"])
		for key in ["fixed_steps", "award_steps"]:
			var steps = []
			for st in v[key]:
				steps.append([int(st[0]), int(st[1])])
			v[key] = steps
	for name in _schema["structs"]:
		_sizes[name] = int(_schema["structs"][name]["size"])
	_fx = _table("ATaskTemplFixedData")
	_ad = _table("AWARD_DATA")
	return true

func _table(struct_name: String) -> Dictionary:
	var out = {}
	for f in _schema["structs"][struct_name]["fields"]:
		out[f[0]] = [int(f[2]), f[1], int(f[3]), int(f[4])]
	return out

# Offset eines Feldes des festen Teils in der Datei-Version
func _off(name: String) -> int:
	return _shift(_fx[name][0], _v["fixed_steps"])

static func _shift(off: int, steps: Array) -> int:
	var s = 0
	for st in steps:
		if st[0] <= off:
			s = st[1]
	return off + s

func _u(raw: PackedByteArray, name: String) -> int:
	return _value(raw, _fx[name], _v["fixed_steps"])

func _ua(raw: PackedByteArray, name: String) -> int:
	return _value(raw, _ad[name], _v["award_steps"])

static func _value(raw: PackedByteArray, f: Array, steps: Array) -> int:
	var o = _shift(f[0], steps)
	match f[3]:
		1: return raw.decode_u8(o)
		2: return raw.decode_u16(o)
		8: return raw.decode_s64(o)
	return raw.decode_u32(o)

func _list(raw: PackedByteArray, count_name: String, array_name: String) -> Array:
	var out = []
	var n = mini(_u(raw, count_name), _fx[array_name][2])
	var o = _off(array_name)
	for i in n:
		out.append(raw.decode_u32(o + 4 * i))
	return out

func _field(raw: PackedByteArray, name: String):
	if raw.is_empty() or not _fx.has(name):
		return null
	var f: Array = _fx[name]
	var o = _off(name)
	if f[1] == "task_char":
		return _wstr(raw, o, f[2])
	if f[2] == 1:
		if f[1] == "float":
			return raw.decode_float(o)
		if f[1] == "bool":
			return raw.decode_u8(o) != 0
		return _value(raw, f, _v["fixed_steps"])
	var out = []
	for i in f[2]:
		match f[3]:
			1: out.append(raw.decode_u8(o + i))
			2: out.append(raw.decode_u16(o + 2 * i))
			4: out.append(raw.decode_float(o + 4 * i) if f[1] == "float" else raw.decode_u32(o + 4 * i))
			_: out.append(raw.slice(o + i * f[3], o + (i + 1) * f[3]))
	return out

# UTF-16 bis zum ersten Null-Zeichen
static func _wstr(b: PackedByteArray, off: int, chars: int) -> String:
	var end = mini(off + chars * 2, b.size())
	var i = off
	while i + 1 < end and (b[i] != 0 or b[i + 1] != 0):
		i += 2
	return b.slice(off, i).get_string_from_utf16() if i > off else ""
