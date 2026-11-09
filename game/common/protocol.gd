extends RefCounted

# ====================================================
# Protokoll zwischen Client und Server (beide Seiten nutzen diese Datei).
# Ablauf: Client verbindet (ENet) -> "hello" mit VERSION -> "register" / "login" -> ... -> "logout".
#   Anfrage  (Client -> Server)  Nummer, Name, Argumente (Dictionary)
#   Antwort  (Server -> Client)  Nummer, Code (Code.OK oder Fehler), Daten (Dictionary)
#   Meldung  (Server -> Client)  Name, Daten, ohne Antwort: "kicked" {code}, "server_closing"
# Anfragen:
#   hello     {version, client}        -> {server, version, started}
#   ping      {}                       -> {time}
#   register  {account, password}      -> {account}
#   login     {account, password, force} -> {account, account_id}
#             force (Anmeldung erzwingen): ein schon angemeldetes Konto wird getrennt, sonst
#             antwortet der Server ACCOUNT_ONLINE
#   logout    {}                       -> {}
#   char_list   {}                     -> {chars: [{id, slot, name, race, class, gender, level,
#                                          appearance, map, last_played}], max,
#                                          classes: ["<Rasse>_<Klasse>_<Geschlecht>" mit Vorlage]}
#   char_create {name, race, class, gender, appearance: {face, mask, hair, skin, hair_color}}
#                                      -> {char}
#   char_delete {id}                   -> {}
#   char_enter  {id}                   -> {char, world, map, pos, dir, hp, mp, exp, money, max_hp, max_mp,
#                                          exp_next}  (Höchstwerte nach Klasse und Stufe, EXP bis zur
#                                          nächsten Stufe; 0 = höchste Stufe)
#   (char_* nur angemeldet; Rasse 1 - 6, Klasse wie clsconfig, Geschlecht 0 / 1)
#   world_ready {}                     -> {id, npcs}   Map geladen: die gewählte Figur steht in der
#                                      Welt; npcs = Anzahl NPCs / Monster in Sicht (npc_enter folgt)
#   world_leave {}                     -> {}     zurück zur Figurenauswahl (Position gespeichert)
#   target  {id}                       -> {id, kind, level, hp, max_hp, mp, max_mp, ...}   Ziel wählen:
#                                          kind "monster" / "npc" (dazu tid) oder "player" (dazu name,
#                                          race, class); nur sichtbare und wählbare Figuren, auch die
#                                          eigene, sonst TARGET_INVALID; id 0 = abwählen -> {id: 0}
#   chat    {channel, text}            -> {}     channel CHAT_SAY ("Sagen"): geht als Meldung
#                                          chat {channel, id, name, text} an alle Figuren derselben Map
#                                          im Umkreis SAY_RANGE, auch an den Sender; Text 1 - CHAT_MAX
#                                          Zeichen ohne Steuerzeichen (sonst CHAT_INVALID), höchstens
#                                          CHAT_BURST Nachrichten in CHAT_WINDOW s (sonst CHAT_TOO_FAST)
#   quest_accept   {npc, id}           -> {id}   Quest beim NPC (Objekt-ID) annehmen (NPC_GIVE_TASK)
#   quest_complete {npc, id}           -> {id}   laufende Quest beim NPC abschließen (NPC_COMPLETE_TASK)
#   quest_abandon  {id}                -> {id}   Quest der obersten Ebene aufgeben (nur mit giveup)
#   world_ready liefert dazu quests {active: [[ID, Fortschritt]], done: [IDs]} (nach der
#   automatischen Vergabe), stats (wie die Meldung stats) und inventory (wie die Meldung inventory)
#   equip     {pos}                    -> {slot}  Gegenstand vom Taschenplatz anlegen (Platz = Bit der
#                                          equip_mask); was dort lag, kommt an den Taschenplatz
#   unequip   {slot, pos}              -> {pos}   ablegen, an Taschenplatz pos (-1 / belegt: der erste freie)
#   move_item {from, to}               -> {}      Taschenplätze tauschen bzw. Stapel zusammenlegen
#   gather    {id}                     -> {id, time}  an einem Sammelpunkt (Objekt-ID) sammeln, Dauer s;
#                                          das Ergebnis kommt als gather_end
#   gather_cancel {}                   -> {}      Sammeln abbrechen
#   char_enter liefert dazu equip [[Platz, ID]] (Modell der eigenen Figur)
#   attack    {id}                     -> {id, interval, range}  Normalangriff auf ein Monster, wiederholt
#                                          alle interval s, solange es in Reichweite ist und lebt
#   attack_stop {}                     -> {}      Normalangriff beenden
#   revive    {}                       -> {pos}   tot: am Wiederbelebungspunkt mit 10 % HP / MP aufstehen
#   world_ready liefert dazu dead (tot gespeichert: Wiederbeleben nötig)
#   skill_seen {ids}                   -> {new}   Fertigkeiten aus dem Fenster "Neue Fertigkeiten" weggelegt
#   shortcut  {bar, slot, id}          -> {bar, slot, id}  Platz einer Schnellleiste (0 unten, 1 rechts,
#                                          Plätze 0 - 9) mit einer bekannten Fertigkeit belegen, id 0 = leeren
#   world_ready liefert dazu skills {skills: [[ID, Stufe]], new: [IDs], shortcuts: [[Leiste, Platz, ID]],
#   info: {ID: Werte}, cool: {ID: ms}}; Meldungen skill_new {id, level} (gelernt), skill_level {id, level},
#   skill_info {id, info} (Werte geändert)
#   Werte einer Fertigkeit (server/skills.gd info): mp, time (Zauberzeit ms), cool (Abklingzeit ms), cast
#   (Annäherung m), range (größte Weite m), min (kleinste Weite m), type (1 Angriff, 2 Segen, 3 Fluch,
#   4 passiv ...), approach (Zielart), instant, act (Aktion der eigenen Figur), auto (danach Normalangriff),
#   usable (lässt sich schon einsetzen)
#   skill_cast {id, target, pos}        -> {id, time}  Fertigkeit auf ein Ziel (Monster) einsetzen; Zaubern
#                                          time ms, dann Wirkung (hit mit skill), Mana und Abklingzeit; pos
#                                          (optional) = Position jetzt (das letzte MOVE kann 0,1 s alt sein und
#                                          beim Ankommen nach dem Rennen sähe das nächste wie Bewegung aus)
#   skill_cancel {}                     -> {}     Zaubern abbrechen (Bewegung)
#   Meldungen: skill_start {src, id, dst, time, act} (jemand in Sicht zaubert; nicht an den Zaubernden),
#   skill_end {src, id, ok} (fertig bzw. ok = false abgebrochen; auch an den Zaubernden), cooldown {id, ms}
#   (Abklingzeit läuft), hit enthält bei Fertigkeiten skill (ID) und elapsed (ms seit Beginn des Zauberns)
#   Statuseffekte (server/buffs.gd): Meldung buffs {id, list: [[Effekt, Stapel, Rest ms (0 = ohne Ende), Dauer ms,
#   Sichtbar-Index (light der Vorlage, -1 = keiner; GFX am Modell aus buff_gfx.lua)]]} (Effekte einer Figur / eines
#   Monsters in Sicht geändert, auch an die Figur selbst; beim Erscheinen in Sicht mit Effekten ebenso), heal {src,
#   dst, amount, buff, hp, max_hp} (Heilung durch einen Effekt), hit mit buff (Effekt-ID) = Schaden über Zeit; target
#   und world_ready liefern buffs (Liste wie oben); stats enthält speed_add (m/s aus Tempo-Effekten)
# Welt (nach world_ready):
#   MOVE   Client -> Server, unzuverlässig, 10 / s: Position x, y, z, Richtung (Bogenmaß), Zustand
#   STATE  Server -> Client, unzuverlässig, bis 10 / s: [[id, x, y, z, Richtung, Zustand], ...] der
#          sichtbaren anderen Figuren, die sich geändert haben (unveränderte spätestens jede Sekunde)
#   Meldungen: player_enter {id, name, race, gender, class, level, appearance, pos, dir} (kommt in Sicht),
#   player_leave {id}, pos_correct {pos, dir} (Bewegung abgelehnt, Figur zurücksetzen)
#   Quests: quests {active, done} (Zustand nach jeder Änderung), quest_event {id, kind ("new" /
#   "done" / "failed" / "bag_full"), exp, gold, items: [[ID, Anzahl, Platz]]}, stats {level, exp,
#   exp_next, hp, max_hp, mp, max_mp, money, attr: {dmg: [min, max], def, hit, eva, crit, crit_dmg,
#   anti_crit, anti_crit_dmg}}
#   Inventar: inventory {size, bag: [[Platz, ID, Anzahl]], equip: [[Platz, ID]]} (nach jeder Änderung),
#   gather_end {id, ok, items: [[ID, Anzahl]]} (Sammeln fertig bzw. abgebrochen), player_equip {id,
#   equip} (Ausrüstung einer sichtbaren Figur geändert; player_enter enthält equip ebenso)
#   Kampf: hit {src, dst, dmg, miss, crit, hp, max_hp} (Treffer in Sicht, src / dst Figur oder Monster),
#   die {id} / revive {id, pos} (Spieler in Sicht stirbt / steht wieder auf; player_enter enthält dead),
#   kill {id, tid, exp} (eigener Todesstoß); Monster sterben mit npc_leave {die: true}
# NPCs und Monster (IDs ab NPC_ID_BASE, Vorlage = ID in elements.data), zuverlässige Meldungen:
#   npc_enter {list: [[id, Vorlage, x, y, z, Richtung, Stufe, Gang], ...]}  kommen in Sicht
#             Gang = [] (steht) oder [Ziel x, y, z, Tempo m/s] (läuft gerade dorthin)
#   npc_move  {id, pos, to, speed}  läuft von pos nach to und bleibt dort stehen
#   npc_leave {ids, die}            aus der Sicht bzw. gestorben (die = true)
# Zustand: MOVE_STAND, MOVE_WALK, MOVE_RUN, MOVE_JUMP
# VERSION bei jeder Änderung erhöhen, die ältere Clients nicht verstehen.
# Die Codes TIMEOUT, DISCONNECTED, NOT_CONNECTED, CONNECT_FAILED setzt der Client selbst.
# ====================================================

const VERSION = 12
const DEFAULT_PORT = 29000
const REQUEST_TIMEOUT = 10.0 # Sekunden bis eine Anfrage ohne Antwort scheitert
const CONNECT_TIMEOUT = 8.0
const HELLO_TIMEOUT = 15.0 # Server trennt Verbindungen ohne "hello" ...
const LOGIN_TIMEOUT = 300.0 # ... und ohne Anmeldung

const MOVE_STAND = 0
const MOVE_WALK = 1
const MOVE_RUN = 2
const MOVE_JUMP = 3
const WALK_SPEED = 1.35 # m/s, elements.data CHARRACTER_CLASS_CONFIG (alle Klassen gleich)
const RUN_SPEED = 4.0
const MOVE_RATE = 10.0 # Positionen je Sekunde (MOVE und STATE)
const VIEW_RANGE = 120.0 # m: Figuren, NPCs und Monster in diesem Umkreis sieht der Spieler
const NPC_ID_BASE = 1 << 30 # IDs von NPCs und Monstern (Figuren haben kleinere)
const CHAT_SAY = 0 # Kanal "Sagen" (GP_CHAT_LOCAL)
const SAY_RANGE = 120.0 # m
const CHAT_MAX = 120 # Zeichen je Nachricht
const CHAT_BURST = 5 # Nachrichten ...
const CHAT_WINDOW = 5.0 # ... in so vielen Sekunden

# Konto-Namen: Buchstabe, dann Buchstaben / Ziffern / _ (Groß- und Kleinschreibung zählt nicht)
const ACCOUNT_MIN = 4
const ACCOUNT_MAX = 20
const PASSWORD_MIN = 6
const PASSWORD_MAX = 64

enum Code {
	OK = 0,
	# vom Client selbst gesetzt
	NOT_CONNECTED = 1,
	CONNECT_FAILED = 2,
	TIMEOUT = 3,
	DISCONNECTED = 4,
	# Anfrage
	BAD_REQUEST = 10,
	UNKNOWN_REQUEST = 11,
	NOT_READY = 12,
	VERSION_MISMATCH = 13,
	TOO_MANY_REQUESTS = 14,
	SERVER_ERROR = 15,
	SERVER_CLOSING = 16,
	# Konto
	NOT_LOGGED_IN = 20,
	ALREADY_LOGGED_IN = 21,
	NAME_INVALID = 22,
	NAME_TAKEN = 23,
	PASSWORD_INVALID = 24,
	WRONG_LOGIN = 25,
	ACCOUNT_BANNED = 26,
	TOO_MANY_ATTEMPTS = 27,
	LOGGED_IN_ELSEWHERE = 28,
	ACCOUNT_ONLINE = 29,
	# Figuren
	CHAR_NAME_INVALID = 30,
	CHAR_NAME_TAKEN = 31,
	CHAR_LIMIT = 32,
	CLASS_CLOSED = 33,
	CHAR_NOT_FOUND = 34,
	NOT_IN_WORLD = 35,
	# Welt
	TARGET_INVALID = 36,
	CHAT_INVALID = 37,
	CHAT_TOO_FAST = 38,
	# Quests
	QUEST_INVALID = 40,
	QUEST_NOT_HERE = 41,
	QUEST_CONDITIONS = 42,
	QUEST_NOT_ACTIVE = 43,
	QUEST_NOT_DONE = 44,
	QUEST_BAG_FULL = 45,
	QUEST_NO_GIVEUP = 46,
	# Inventar, Sammeln
	ITEM_INVALID = 50,
	ITEM_CANNOT_EQUIP = 51,
	ITEM_REQUIREMENTS = 52,
	BAG_FULL = 53,
	GATHER_INVALID = 54,
	GATHER_TOO_FAR = 55,
	GATHER_NO_TASK = 56,
	GATHER_BUSY = 57,
	# Kampf
	ATTACK_INVALID = 60,
	YOU_ARE_DEAD = 61,
	NOT_DEAD = 62,
	# Fertigkeiten
	SKILL_UNKNOWN = 70,
	SHORTCUT_INVALID = 71,
	SKILL_COOLDOWN = 72,
	NO_MANA = 73,
	OUT_OF_RANGE = 74,
	TOO_CLOSE = 75,
	SKILL_BUSY = 76,
	SKILL_NOT_YET = 77,
	NO_TARGET = 78,
}

const TEXTS = {
	Code.OK: "OK",
	Code.NOT_CONNECTED: "Nicht mit dem Server verbunden.",
	Code.CONNECT_FAILED: "Server nicht erreichbar.",
	Code.TIMEOUT: "Der Server antwortet nicht.",
	Code.DISCONNECTED: "Verbindung zum Server getrennt.",
	Code.BAD_REQUEST: "Ungültige Anfrage.",
	Code.UNKNOWN_REQUEST: "Unbekannte Anfrage.",
	Code.NOT_READY: "Verbindung noch nicht bereit.",
	Code.VERSION_MISMATCH: "Client und Server haben verschiedene Versionen.",
	Code.TOO_MANY_REQUESTS: "Zu viele Anfragen.",
	Code.SERVER_ERROR: "Fehler auf dem Server.",
	Code.SERVER_CLOSING: "Der Server wird beendet.",
	Code.NOT_LOGGED_IN: "Nicht angemeldet.",
	Code.ALREADY_LOGGED_IN: "Bereits angemeldet.",
	Code.NAME_INVALID: "Kontoname ungültig (4 - 20 Zeichen: Buchstabe, dann Buchstaben, Ziffern oder _).",
	Code.NAME_TAKEN: "Diesen Kontonamen gibt es schon.",
	Code.PASSWORD_INVALID: "Passwort ungültig (6 - 64 Zeichen).",
	Code.WRONG_LOGIN: "Kontoname oder Passwort falsch.",
	Code.ACCOUNT_BANNED: "Dieses Konto ist gesperrt.",
	Code.TOO_MANY_ATTEMPTS: "Zu viele Fehlversuche, bitte später erneut versuchen.",
	Code.LOGGED_IN_ELSEWHERE: "Mit diesem Konto hat sich jemand anderes angemeldet.",
	Code.ACCOUNT_ONLINE: "Dieses Konto ist schon angemeldet. Mit \"Anmeldung erzwingen\" wird die andere Sitzung getrennt.",
	Code.CHAR_NAME_INVALID: "Ungültiger Name (2 - 12 Buchstaben oder Ziffern, vorn ein Buchstabe, keine unerlaubten Wörter).",
	Code.CHAR_NAME_TAKEN: "Diesen Namen gibt es schon.",
	Code.CHAR_LIMIT: "Es sind schon alle Plätze für Figuren belegt.",
	Code.CLASS_CLOSED: "Diese Klasse ist noch nicht offen. Bitte wähle eine andere Klasse.",
	Code.CHAR_NOT_FOUND: "Diese Figur gibt es nicht.",
	Code.NOT_IN_WORLD: "Keine Figur ausgewählt.",
	Code.TARGET_INVALID: "Dieses Ziel kann nicht gewählt werden.",
	Code.CHAT_INVALID: "Diese Nachricht kann nicht gesendet werden.",
	Code.CHAT_TOO_FAST: "Ihr sprecht zu schnell, bitte wartet kurz.",
	Code.QUEST_INVALID: "Diese Quest gibt es nicht.",
	Code.QUEST_NOT_HERE: "Diese Quest gibt es nicht bei diesem NPC, oder Ihr seid zu weit entfernt.",
	Code.QUEST_CONDITIONS: "Ihr erfüllt die Bedingungen für diese Quest nicht.",
	Code.QUEST_NOT_ACTIVE: "Diese Quest habt Ihr nicht.",
	Code.QUEST_NOT_DONE: "Diese Quest ist noch nicht erfüllt.",
	Code.QUEST_BAG_FULL: "Euer Inventar ist voll.",
	Code.QUEST_NO_GIVEUP: "Diese Quest kann nicht aufgegeben werden.",
	Code.ITEM_INVALID: "Diesen Gegenstand gibt es dort nicht.",
	Code.ITEM_CANNOT_EQUIP: "Diesen Gegenstand kann man nicht anlegen.",
	Code.ITEM_REQUIREMENTS: "Ihr erfüllt die Bedingungen für diesen Gegenstand nicht (Stufe, Klasse, Rasse oder Geschlecht).",
	Code.BAG_FULL: "Euer Inventar ist voll.",
	Code.GATHER_INVALID: "Hier kann nichts gesammelt werden.",
	Code.GATHER_TOO_FAR: "Ihr seid zu weit entfernt.",
	Code.GATHER_NO_TASK: "Dafür fehlt Euch die passende Quest.",
	Code.GATHER_BUSY: "Hier wird schon gesammelt.",
	Code.ATTACK_INVALID: "Dieses Ziel kann nicht angegriffen werden.",
	Code.YOU_ARE_DEAD: "Ihr seid tot.",
	Code.NOT_DEAD: "Ihr seid nicht tot.",
	Code.SKILL_UNKNOWN: "Diese Fertigkeit kennt Ihr nicht.",
	Code.SHORTCUT_INVALID: "Diesen Platz gibt es nicht.",
	Code.SKILL_COOLDOWN: "Diese Fertigkeit ist noch nicht bereit.",
	Code.NO_MANA: "Nicht genug Mana.",
	Code.OUT_OF_RANGE: "Das Ziel ist zu weit entfernt.",
	Code.TOO_CLOSE: "Das Ziel ist zu nah.",
	Code.SKILL_BUSY: "Ihr wirkt gerade eine andere Fertigkeit.",
	Code.SKILL_NOT_YET: "Diese Fertigkeit lässt sich noch nicht einsetzen.",
	Code.NO_TARGET: "Kein gültiges Ziel ausgewählt.",
}

# Texte in den anderen Sprachordnern der Spieldaten (fehlt einer, gilt der deutsche)
const TEXTS_BY_LANGUAGE = {
	"Eng": {
		Code.OK: "OK",
		Code.NOT_CONNECTED: "Not connected to the server.",
		Code.CONNECT_FAILED: "The server cannot be reached.",
		Code.TIMEOUT: "The server does not respond.",
		Code.DISCONNECTED: "Connection to the server lost.",
		Code.BAD_REQUEST: "Invalid request.",
		Code.UNKNOWN_REQUEST: "Unknown request.",
		Code.NOT_READY: "Connection not ready yet.",
		Code.VERSION_MISMATCH: "Client and server versions differ.",
		Code.TOO_MANY_REQUESTS: "Too many requests.",
		Code.SERVER_ERROR: "Server error.",
		Code.SERVER_CLOSING: "The server is shutting down.",
		Code.NOT_LOGGED_IN: "Not logged in.",
		Code.ALREADY_LOGGED_IN: "Already logged in.",
		Code.NAME_INVALID: "Invalid account name (4 - 20 characters: a letter, then letters, digits or _).",
		Code.NAME_TAKEN: "This account name already exists.",
		Code.PASSWORD_INVALID: "Invalid password (6 - 64 characters).",
		Code.WRONG_LOGIN: "Wrong account name or password.",
		Code.ACCOUNT_BANNED: "This account is banned.",
		Code.TOO_MANY_ATTEMPTS: "Too many failed attempts, please try again later.",
		Code.LOGGED_IN_ELSEWHERE: "Someone else has logged in with this account.",
		Code.ACCOUNT_ONLINE: "This account is already logged in. Use \"Force login\" to disconnect the other session.",
		Code.CHAR_NAME_INVALID: "Invalid name (2 - 12 letters or digits, starting with a letter, no forbidden words).",
		Code.CHAR_NAME_TAKEN: "This name is already taken.",
		Code.CHAR_LIMIT: "All character slots are in use.",
		Code.CLASS_CLOSED: "This class is not available yet. Please choose another class.",
		Code.CHAR_NOT_FOUND: "This character does not exist.",
		Code.NOT_IN_WORLD: "No character selected.",
		Code.TARGET_INVALID: "This target cannot be selected.",
		Code.CHAT_INVALID: "This message cannot be sent.",
		Code.CHAT_TOO_FAST: "You are talking too fast, please wait a moment.",
		Code.QUEST_INVALID: "This quest does not exist.",
		Code.QUEST_NOT_HERE: "This NPC does not offer this quest, or you are too far away.",
		Code.QUEST_CONDITIONS: "You do not meet the requirements for this quest.",
		Code.QUEST_NOT_ACTIVE: "You do not have this quest.",
		Code.QUEST_NOT_DONE: "This quest is not completed yet.",
		Code.QUEST_BAG_FULL: "Your inventory is full.",
		Code.QUEST_NO_GIVEUP: "This quest cannot be abandoned.",
		Code.ITEM_INVALID: "This item is not there.",
		Code.ITEM_CANNOT_EQUIP: "This item cannot be equipped.",
		Code.ITEM_REQUIREMENTS: "You do not meet the requirements for this item (level, class, race or gender).",
		Code.BAG_FULL: "Your inventory is full.",
		Code.GATHER_INVALID: "There is nothing to gather here.",
		Code.GATHER_TOO_FAR: "You are too far away.",
		Code.GATHER_NO_TASK: "You need the matching quest for this.",
		Code.GATHER_BUSY: "Someone is already gathering here.",
		Code.ATTACK_INVALID: "This target cannot be attacked.",
		Code.YOU_ARE_DEAD: "You are dead.",
		Code.NOT_DEAD: "You are not dead.",
		Code.SKILL_UNKNOWN: "You do not know this skill.",
		Code.SHORTCUT_INVALID: "This slot does not exist.",
		Code.SKILL_COOLDOWN: "This skill is not ready yet.",
		Code.NO_MANA: "Not enough mana.",
		Code.OUT_OF_RANGE: "The target is too far away.",
		Code.TOO_CLOSE: "The target is too close.",
		Code.SKILL_BUSY: "You are already using a skill.",
		Code.SKILL_NOT_YET: "This skill cannot be used yet.",
		Code.NO_TARGET: "No valid target selected.",
	},
	"Franz": {
		Code.OK: "OK",
		Code.NOT_CONNECTED: "Pas de connexion au serveur.",
		Code.CONNECT_FAILED: "Le serveur est injoignable.",
		Code.TIMEOUT: "Le serveur ne répond pas.",
		Code.DISCONNECTED: "Connexion au serveur perdue.",
		Code.BAD_REQUEST: "Requête invalide.",
		Code.UNKNOWN_REQUEST: "Requête inconnue.",
		Code.NOT_READY: "Connexion pas encore prête.",
		Code.VERSION_MISMATCH: "Les versions du client et du serveur diffèrent.",
		Code.TOO_MANY_REQUESTS: "Trop de requêtes.",
		Code.SERVER_ERROR: "Erreur du serveur.",
		Code.SERVER_CLOSING: "Le serveur s'arrête.",
		Code.NOT_LOGGED_IN: "Non connecté.",
		Code.ALREADY_LOGGED_IN: "Déjà connecté.",
		Code.NAME_INVALID: "Nom de compte invalide (4 à 20 caractères : une lettre, puis lettres, chiffres ou _).",
		Code.NAME_TAKEN: "Ce nom de compte existe déjà.",
		Code.PASSWORD_INVALID: "Mot de passe invalide (6 à 64 caractères).",
		Code.WRONG_LOGIN: "Nom de compte ou mot de passe incorrect.",
		Code.ACCOUNT_BANNED: "Ce compte est bloqué.",
		Code.TOO_MANY_ATTEMPTS: "Trop d'essais échoués, veuillez réessayer plus tard.",
		Code.LOGGED_IN_ELSEWHERE: "Quelqu'un d'autre s'est connecté avec ce compte.",
		Code.ACCOUNT_ONLINE: "Ce compte est déjà connecté. « Forcer la connexion » déconnecte l'autre session.",
		Code.CHAR_NAME_INVALID: "Nom invalide (2 à 12 lettres ou chiffres, commençant par une lettre, sans mots interdits).",
		Code.CHAR_NAME_TAKEN: "Ce nom est déjà pris.",
		Code.CHAR_LIMIT: "Tous les emplacements de personnage sont occupés.",
		Code.CLASS_CLOSED: "Cette classe n'est pas encore disponible. Veuillez en choisir une autre.",
		Code.CHAR_NOT_FOUND: "Ce personnage n'existe pas.",
		Code.NOT_IN_WORLD: "Aucun personnage sélectionné.",
		Code.TARGET_INVALID: "Cette cible ne peut pas être sélectionnée.",
		Code.CHAT_INVALID: "Ce message ne peut pas être envoyé.",
		Code.CHAT_TOO_FAST: "Vous parlez trop vite, veuillez patienter un instant.",
		Code.QUEST_INVALID: "Cette quête n'existe pas.",
		Code.QUEST_NOT_HERE: "Ce PNJ ne propose pas cette quête, ou vous êtes trop loin.",
		Code.QUEST_CONDITIONS: "Vous ne remplissez pas les conditions de cette quête.",
		Code.QUEST_NOT_ACTIVE: "Vous n'avez pas cette quête.",
		Code.QUEST_NOT_DONE: "Cette quête n'est pas encore terminée.",
		Code.QUEST_BAG_FULL: "Votre inventaire est plein.",
		Code.QUEST_NO_GIVEUP: "Cette quête ne peut pas être abandonnée.",
		Code.ITEM_INVALID: "Cet objet n'est pas là.",
		Code.ITEM_CANNOT_EQUIP: "Cet objet ne peut pas être équipé.",
		Code.ITEM_REQUIREMENTS: "Vous ne remplissez pas les conditions de cet objet (niveau, classe, race ou sexe).",
		Code.BAG_FULL: "Votre inventaire est plein.",
		Code.GATHER_INVALID: "Il n'y a rien à récolter ici.",
		Code.GATHER_TOO_FAR: "Vous êtes trop loin.",
		Code.GATHER_NO_TASK: "Il vous faut la quête correspondante.",
		Code.GATHER_BUSY: "Quelqu'un récolte déjà ici.",
		Code.ATTACK_INVALID: "Cette cible ne peut pas être attaquée.",
		Code.YOU_ARE_DEAD: "Vous êtes mort.",
		Code.NOT_DEAD: "Vous n'êtes pas mort.",
		Code.SKILL_UNKNOWN: "Vous ne connaissez pas cette compétence.",
		Code.SHORTCUT_INVALID: "Cet emplacement n'existe pas.",
		Code.SKILL_COOLDOWN: "Cette compétence n'est pas encore prête.",
		Code.NO_MANA: "Pas assez de mana.",
		Code.OUT_OF_RANGE: "La cible est trop loin.",
		Code.TOO_CLOSE: "La cible est trop proche.",
		Code.SKILL_BUSY: "Vous utilisez déjà une compétence.",
		Code.SKILL_NOT_YET: "Cette compétence ne peut pas encore être utilisée.",
		Code.NO_TARGET: "Aucune cible valide sélectionnée.",
	},
}


static func text(code: int, language: String = "Deu") -> String:
	var table: Dictionary = TEXTS_BY_LANGUAGE.get(language, TEXTS)
	return table.get(code, TEXTS.get(code, "Fehler %d" % code))

static func result(code: int, data: Dictionary = {}) -> Dictionary:
	return {"code": code, "data": data}
