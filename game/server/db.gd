extends RefCounted

# ====================================================
# Kleine Hülle über die SQLite-Erweiterung (addons/sqlite3.gd, Klassen Sqlite3Wrapper /
# Sqlite3Handle / Sqlite3StmtHandle). Die Klassen werden über ClassDB angesprochen, damit
# Skripte ohne die Erweiterung (z.B. ein Client-Export) trotzdem laden.
#   open(pfad) -> "" oder Fehler          close()
#   query(sql, [werte]) -> [{spalte: wert}] oder null bei Fehler (last_error)
#   run(sql, [werte]) -> bool             scalar(sql, [werte]) -> erster Wert oder null
#   exec(sql) -> bool (mehrere Befehle, ohne Werte)
#   begin() / commit() / rollback(), last_id(), changes()
# Werte werden immer gebunden (?), nie in den SQL-Text eingesetzt.
# ====================================================

const ROW = 100 # SQLITE_ROW
const DONE = 101 # SQLITE_DONE
const T_INTEGER = 1
const T_FLOAT = 2
const T_TEXT = 3
const T_BLOB = 4

var path = ""
var last_error = ""
var _s: Object # Sqlite3Wrapper
var _db: Object # Sqlite3Handle


static func available() -> bool:
	return ClassDB.class_exists(&"Sqlite3Wrapper")

func open(file: String) -> String:
	close()
	if not available():
		return "Не загружено расширение SQLite (addons/sqlite3.gd)"
	path = ProjectSettings.globalize_path(file)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_s = ClassDB.instantiate(&"Sqlite3Wrapper")
	_db = ClassDB.instantiate(&"Sqlite3Handle")
	if _s.open(path, _db) != 0:
		var msg = "%s: %s" % [path, _s.errmsg(_db)]
		close()
		return msg
	if not exec("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 2000;"):
		var msg = last_error
		close()
		return msg
	return ""

func close() -> void:
	if _db != null and _db.is_valid():
		_s.close_v2(_db)
	_db = null

func is_open() -> bool:
	return _db != null and _db.is_valid()

func exec(sql: String) -> bool:
	var r: Dictionary = _s.exec(_db, sql, Callable())
	if int(r.get("code", 1)) != 0:
		return _fail(str(r.get("error_message", "")), sql)
	return true

func query(sql: String, params: Array = []) -> Variant:
	var st = _prepare(sql, params)
	if st == null:
		return null
	var cols = []
	for i in _s.column_count(st):
		cols.append(_s.column_name(st, i))
	var rows = []
	while true:
		var rc = _s.step(st)
		if rc == ROW:
			var row = {}
			for i in cols.size():
				row[cols[i]] = _column(st, i)
			rows.append(row)
		elif rc == DONE:
			break
		else:
			_fail(_s.errmsg(_db), sql)
			_s.finalize(st)
			return null
	_s.finalize(st)
	return rows

func run(sql: String, params: Array = []) -> bool:
	return query(sql, params) != null

func scalar(sql: String, params: Array = []) -> Variant:
	var rows = query(sql, params)
	if rows == null or rows.is_empty():
		return null
	return rows[0].values()[0]

func begin() -> bool:
	return exec("BEGIN IMMEDIATE")

func commit() -> bool:
	return exec("COMMIT")

func rollback() -> void:
	exec("ROLLBACK")

func last_id() -> int:
	return _s.last_insert_rowid(_db)

func changes() -> int:
	return _s.changes(_db)

func _prepare(sql: String, params: Array) -> Object:
	if not is_open():
		_fail("База данных не открыта", sql)
		return null
	var r: Dictionary = _s.prepare_v2(_db, sql, -1)
	var st = r.get("statement")
	if int(r.get("error_code", 1)) != 0 or st == null:
		_fail(_s.errmsg(_db), sql)
		return null
	for i in params.size():
		var v = params[i]
		var rc = 0
		match typeof(v):
			TYPE_NIL:
				rc = _s.bind_null(st, i + 1)
			TYPE_BOOL, TYPE_INT:
				rc = _s.bind_int64(st, i + 1, int(v))
			TYPE_FLOAT:
				rc = _s.bind_double(st, i + 1, v)
			TYPE_PACKED_BYTE_ARRAY:
				rc = _s.bind_blob(st, i + 1, v)
			_:
				rc = _s.bind_text(st, i + 1, str(v), -1, _s.transient_destructor_type())
		if rc != 0:
			_fail("Wert %d: %s" % [i + 1, _s.errmsg(_db)], sql)
			_s.finalize(st)
			return null
	return st

func _column(st: Object, i: int) -> Variant:
	match _s.column_type(st, i):
		T_INTEGER:
			return _s.column_int64(st, i)
		T_FLOAT:
			return _s.column_double(st, i)
		T_TEXT:
			return _s.column_text(st, i)
		T_BLOB:
			return _s.column_blob(st, i)
	return null

func _fail(msg: String, sql: String) -> bool:
	last_error = "%s (%s)" % [msg, sql.strip_edges().left(80)]
	return false
