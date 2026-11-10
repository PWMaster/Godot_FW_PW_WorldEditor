extends RefCounted

# ====================================================
# Aufbau der Spiel-Datenbank. MIGRATIONS[i] bringt die DB von Version i auf i + 1 (PRAGMA
# user_version); neue Änderungen nur hinten anfügen, nie alte ändern.
#   accounts    Konten (Passwort nur als Hash, siehe accounts.gd), Sperre
#   characters  Figuren je Konto (Platz, Rasse / Klasse / Geschlecht wie clsconfig, Aussehen
#               als JSON, Welt-Nummer aus gs.conf, Client-Map, Position, Richtung)
#   inventory   Gegenstände (Ort 0 Tasche, 1 Ausrüstung, 2 Lager; Platz; elements-ID; Anzahl)
#   quests      Quest-Zustand je Figur (1 aktiv, 2 abgegeben, 3 gescheitert), Fortschritt als JSON
#   skills      bekannte Fertigkeiten je Figur (Stufe, new = noch im Fenster "Neue Fertigkeiten")
#   shortcuts   Schnellleisten je Figur (Leiste, Platz, Fertigkeit)
# Zeiten als Unix-Zeit (Sekunden).
# ====================================================

const MIGRATIONS = [
	"""
	CREATE TABLE accounts (
		id INTEGER PRIMARY KEY,
		name TEXT NOT NULL UNIQUE COLLATE NOCASE,
		pw_hash TEXT NOT NULL,
		created INTEGER NOT NULL,
		last_login INTEGER,
		last_address TEXT,
		banned_until INTEGER NOT NULL DEFAULT 0, -- 0 frei, -1 dauerhaft, sonst bis Unix-Zeit
		ban_reason TEXT NOT NULL DEFAULT ''
	);
	CREATE TABLE characters (
		id INTEGER PRIMARY KEY,
		account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
		slot INTEGER NOT NULL,
		name TEXT NOT NULL UNIQUE COLLATE NOCASE,
		race INTEGER NOT NULL,
		class INTEGER NOT NULL,
		gender INTEGER NOT NULL,
		appearance TEXT NOT NULL DEFAULT '{}',
		level INTEGER NOT NULL DEFAULT 1,
		exp INTEGER NOT NULL DEFAULT 0,
		hp INTEGER NOT NULL DEFAULT 0,
		mp INTEGER NOT NULL DEFAULT 0,
		money INTEGER NOT NULL DEFAULT 0,
		world INTEGER NOT NULL,
		map TEXT NOT NULL,
		pos_x REAL NOT NULL DEFAULT 0,
		pos_y REAL NOT NULL DEFAULT 0,
		pos_z REAL NOT NULL DEFAULT 0,
		dir REAL NOT NULL DEFAULT 0,
		created INTEGER NOT NULL,
		last_played INTEGER,
		deleted INTEGER NOT NULL DEFAULT 0, -- 0 oder Zeitpunkt des Löschens
		UNIQUE (account_id, slot)
	);
	CREATE TABLE inventory (
		character_id INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
		location INTEGER NOT NULL,
		pos INTEGER NOT NULL,
		item_id INTEGER NOT NULL,
		count INTEGER NOT NULL DEFAULT 1,
		data BLOB,
		PRIMARY KEY (character_id, location, pos)
	);
	CREATE TABLE quests (
		character_id INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
		task_id INTEGER NOT NULL,
		state INTEGER NOT NULL,
		progress TEXT NOT NULL DEFAULT '{}',
		accepted INTEGER,
		finished INTEGER,
		times INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY (character_id, task_id)
	);
	CREATE INDEX characters_account ON characters(account_id);
	""",
	"""
	CREATE TABLE skills (
		character_id INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
		skill_id INTEGER NOT NULL,
		level INTEGER NOT NULL DEFAULT 1,
		new INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY (character_id, skill_id)
	);
	CREATE TABLE shortcuts (
		character_id INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
		bar INTEGER NOT NULL,
		slot INTEGER NOT NULL,
		skill_id INTEGER NOT NULL,
		PRIMARY KEY (character_id, bar, slot)
	);
	""",
]


static func version() -> int:
	return MIGRATIONS.size()

# DB auf den neuesten Stand bringen -> "" oder Fehler
static func migrate(db) -> String:
	var v = db.scalar("PRAGMA user_version")
	if v == null:
		return db.last_error
	v = int(v)
	if v > MIGRATIONS.size():
		return "Версия базы данных %d новее поддерживаемой этой игрой версии %d" % [v, MIGRATIONS.size()]
	while v < MIGRATIONS.size():
		if not db.begin():
			return db.last_error
		if not db.exec(MIGRATIONS[v]) or not db.exec("PRAGMA user_version = %d" % (v + 1)):
			var msg = db.last_error
			db.rollback()
			return "Umbau auf Version %d: %s" % [v + 1, msg]
		if not db.commit():
			return db.last_error
		v += 1
	return ""
