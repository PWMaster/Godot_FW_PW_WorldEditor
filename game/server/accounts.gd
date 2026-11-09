extends RefCounted

# ====================================================
# Konten des Servers: anlegen und anmelden.
# Passwort nur als Hash: PBKDF2-HMAC-SHA256 mit zufälligem Salt, gespeichert als
#   "pbkdf2_sha256$<Runden>$<Salt hex>$<Hash hex>"  (Runden stehen im Text, ITERATIONS darf steigen)
# Fehlversuche: je Konto MAX_FAILS in FAIL_WINDOW Sekunden, danach Code TOO_MANY_ATTEMPTS (auch
# mit richtigem Passwort) bis der älteste Versuch aus dem Fenster fällt; je Adresse MAX_FAILS_ADDRESS
# und MAX_REGISTER_ADDRESS neue Konten je Stunde. Für 127.0.0.1 / ::1 (Tests) gilt keine
# Adress-Grenze. Die Zähler liegen im Speicher (Neustart setzt sie zurück).
# Unbekannte Konten kosten dieselbe Rechenzeit wie falsche Passwörter (kein Erraten von Namen).
# Wer online ist, verwaltet server.gd.
# Damit der Hash (50 - 150 ms je nach Rechner) den Server nicht anhält, gehen Anlegen und Anmelden in
# drei Teilen:
#   register_begin / login_begin   prüfen sofort (Name, Sperren, Datenbank) -> {result: [Code, Daten]}
#                                  oder einen Auftrag {password, stored | salt, ...}
#   run_job(Auftrag)               rechnet den Hash in einem Hintergrund-Thread (server.gd:
#                                  WorkerThreadPool), ohne Datenbank und ohne gemeinsame Daten
#   register_finish / login_finish wieder im Haupt-Thread -> [Code, Daten]
# Laufende Anmeldungen zählen bei der Sperre mit (sonst ließen sich viele gleichzeitig raten).
# Godots Krypto-Aufrufe (hmac_digest, HashingContext) sperren sich prozessweit, mehrere Hashes laufen
# also kaum schneller als nacheinander: gut 10 Anmeldungen je Sekunde, gleichzeitige warten - der
# Server selbst läuft dabei weiter (Lasttest: 50 Bots, längstes Bild unter 40 ms).
# ====================================================

const Proto = preload("../common/protocol.gd")
const HASH_NAME = "pbkdf2_sha256"
const ITERATIONS = 50000 # 50 - 150 ms je Anmeldung (im Hintergrund-Thread)
const SALT_BYTES = 16
const MAX_FAILS = 5
const FAIL_WINDOW = 300
const MAX_FAILS_ADDRESS = 30
const MAX_REGISTER_ADDRESS = 10
const REGISTER_WINDOW = 3600
const LOCAL_ADDRESSES = ["127.0.0.1", "::1", "::ffff:127.0.0.1"]

var db
var _crypto = Crypto.new()
var _name_re = RegEx.new()
var _fails = {} # "a:<name>" / "i:<Adresse>" -> [Zeitpunkte]
var _registers = {} # Adresse -> [Zeitpunkte]
var _pending = {} # "a:<name>" / "i:<Adresse>" -> laufende Anmeldungen
var _dummy_hash = ""


func _init(p_db) -> void:
	db = p_db
	_name_re.compile("^[A-Za-z][A-Za-z0-9_]{%d,%d}$" % [Proto.ACCOUNT_MIN - 1, Proto.ACCOUNT_MAX - 1])
	_dummy_hash = hash_password("-")

func valid_name(account: String) -> bool:
	return _name_re.search(account) != null

static func valid_password(password: String) -> bool:
	if password.length() < Proto.PASSWORD_MIN or password.length() > Proto.PASSWORD_MAX:
		return false
	for c in password:
		if c.unicode_at(0) < 32:
			return false
	return true


# ====================================================
# ANLEGEN / ANMELDEN -> [Code, Daten]
# ====================================================
func register_begin(account: String, password: String, address: String) -> Dictionary:
	if not valid_name(account):
		return {"result": [Proto.Code.NAME_INVALID, {}]}
	if not valid_password(password):
		return {"result": [Proto.Code.PASSWORD_INVALID, {}]}
	if not _is_local(address) and _count(_registers, address, REGISTER_WINDOW) >= MAX_REGISTER_ADDRESS:
		return {"result": [Proto.Code.TOO_MANY_ATTEMPTS, {}]}
	var taken = _taken(account)
	if taken != Proto.Code.OK:
		return {"result": [taken, {}]}
	return {"account": account, "password": password, "salt": _crypto.generate_random_bytes(SALT_BYTES), "address": address}

func register_finish(job: Dictionary) -> Array:
	var taken = _taken(job["account"]) # gleichzeitig angelegt?
	if taken != Proto.Code.OK:
		return [taken, {}]
	if not db.run("INSERT INTO accounts (name, pw_hash, created) VALUES (?, ?, ?)", [job["account"], job["hash"], now()]):
		return [Proto.Code.SERVER_ERROR, {}]
	_add(_registers, job["address"])
	return [Proto.Code.OK, {"account": job["account"]}]

func login_begin(account: String, password: String, address: String) -> Dictionary:
	var key = "a:" + account.to_lower()
	var ip = "i:" + address
	if _count(_fails, key, FAIL_WINDOW) + _pending.get(key, 0) >= MAX_FAILS:
		return {"result": [Proto.Code.TOO_MANY_ATTEMPTS, {}]}
	if not _is_local(address) and _count(_fails, ip, FAIL_WINDOW) + _pending.get(ip, 0) >= MAX_FAILS_ADDRESS:
		return {"result": [Proto.Code.TOO_MANY_ATTEMPTS, {}]}
	var rows = []
	if valid_name(account) and password.length() <= Proto.PASSWORD_MAX:
		rows = db.query("SELECT id, name, pw_hash, banned_until, ban_reason FROM accounts WHERE name = ?", [account])
		if rows == null:
			return {"result": [Proto.Code.SERVER_ERROR, {}]}
	var row = rows[0] if not rows.is_empty() else {}
	_pending[key] = _pending.get(key, 0) + 1
	_pending[ip] = _pending.get(ip, 0) + 1
	return {"key": key, "ip": ip, "address": address, "row": row, "password": password,
		"stored": row.get("pw_hash", _dummy_hash)}

func login_finish(job: Dictionary) -> Array:
	var key: String = job["key"]
	for k in [key, job["ip"]]:
		_pending[k] = _pending.get(k, 1) - 1
		if _pending[k] <= 0:
			_pending.erase(k)
	var row: Dictionary = job["row"]
	if not job.get("ok", false) or row.is_empty():
		_add(_fails, key)
		_add(_fails, job["ip"])
		return [Proto.Code.WRONG_LOGIN, {}]
	var until = int(row["banned_until"])
	if until == -1 or until > now():
		return [Proto.Code.ACCOUNT_BANNED, {"until": until, "reason": row["ban_reason"]}]
	_fails.erase(key)
	db.run("UPDATE accounts SET last_login = ?, last_address = ? WHERE id = ?", [now(), job["address"], row["id"]])
	return [Proto.Code.OK, {"account": row["name"], "account_id": row["id"]}]

# Im Hintergrund-Thread: nur rechnen (Anmelden: ok, Anlegen: hash)
static func run_job(job: Dictionary) -> void:
	if job.has("stored"):
		job["ok"] = verify_password(job["password"], job["stored"])
	else:
		job["hash"] = hash_with_salt(job["password"], job["salt"], ITERATIONS)

func _taken(account: String) -> int:
	var existing = db.query("SELECT id FROM accounts WHERE name = ?", [account])
	if existing == null:
		return Proto.Code.SERVER_ERROR
	return Proto.Code.OK if existing.is_empty() else Proto.Code.NAME_TAKEN


# ====================================================
# PASSWORT-HASH
# ====================================================
func hash_password(password: String, iterations: int = ITERATIONS) -> String:
	return hash_with_salt(password, _crypto.generate_random_bytes(SALT_BYTES), iterations)

static func hash_with_salt(password: String, salt: PackedByteArray, iterations: int) -> String:
	var h = pbkdf2_sha256(password.to_utf8_buffer(), salt, iterations)
	return "%s$%d$%s$%s" % [HASH_NAME, iterations, salt.hex_encode(), h.hex_encode()]

static func verify_password(password: String, stored: String) -> bool:
	var parts = stored.split("$")
	if parts.size() != 4 or parts[0] != HASH_NAME or not parts[1].is_valid_int():
		return false
	var h = pbkdf2_sha256(password.to_utf8_buffer(), parts[2].hex_decode(), parts[1].to_int())
	return _same(h, parts[3].hex_decode())

# PBKDF2-HMAC-SHA256 (RFC 8018) mit 32 Byte Ergebnis (ein Block)
static func pbkdf2_sha256(password: PackedByteArray, salt: PackedByteArray, iterations: int) -> PackedByteArray:
	var crypto = Crypto.new()
	var block = salt.duplicate()
	block.append_array(PackedByteArray([0, 0, 0, 1]))
	var u = crypto.hmac_digest(HashingContext.HASH_SHA256, password, block)
	var t = u.to_int64_array()
	for i in iterations - 1:
		u = crypto.hmac_digest(HashingContext.HASH_SHA256, password, u)
		var x = u.to_int64_array()
		t[0] ^= x[0]
		t[1] ^= x[1]
		t[2] ^= x[2]
		t[3] ^= x[3]
	return t.to_byte_array()

# Vergleich in gleicher Zeit, egal wo der erste Unterschied liegt
static func _same(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff = 0
	for i in a.size():
		diff |= a[i] ^ b[i]
	return diff == 0


# ====================================================
# ZÄHLER
# ====================================================
static func now() -> int:
	return int(Time.get_unix_time_from_system())

static func _is_local(address: String) -> bool:
	return address in LOCAL_ADDRESSES

func _add(table: Dictionary, key: String) -> void:
	if not table.has(key):
		table[key] = []
	table[key].append(now())

# Anzahl der Einträge in den letzten window Sekunden (ältere werden entfernt)
func _count(table: Dictionary, key: String, window: int) -> int:
	var list: Array = table.get(key, [])
	var limit = now() - window
	while not list.is_empty() and list[0] <= limit:
		list.pop_front()
	if list.is_empty():
		table.erase(key)
	return list.size()
