extends Node

# ====================================================
# Spiel-Oberfläche in der Welt (Fahrplan Schritt 8) nach CECGameUIMan, DlgHost, DlgTarget, DlgChat,
# DlgMiniMap und DlgWinTop: die Dialoge der Liste <Skin>gameui (.dcf / .stf der Spieldaten; Skin 2 =
# neuere Oberfläche, 1 = ältere, Einstellung ui_skin; fehlt die Liste, gilt die andere) auf einer
# eigenen AUI-Ebene (ui/aui_manager.gd):
#   Win_CharHead     eigener Kopf: Name, Stufe, Klasse (Pic_Prof0 Bild Klasse - 1), HP / MP mit Zahlen,
#                    XP 0/100 (DlgHost::RefreshHostStats)
#   Win_Target*      Ziel (Monster / NPC / Spieler): Name in der Namensfarbe, Stufe, HP / MP, Statuseffekte
#                    (st_1..8 Stärkungen, debuff_1..8 Schwächungen: Symbol, Stapel; CDlgTarget)
#   Win_Buff         eigene Statuseffekte oben rechts (CDlgBuff::UpdateBuff): Img_Buff0 = lange Stärkungen
#                    (Gesamtdauer ab 30 min; Anzahl, Liste im Tooltip), ab Img_Buff1 die übrigen Stärkungen,
#                    Schwächungen ab der nächsten vollen Reihe (je 10, rechts beginnend); Restzeit Txt_Time
#                    (h / m / s, unter 30 s rot), Stapel auf dem Symbol, Sammelplätze bei zu vielen. Art / Symbol /
#                    Text aus Plugin Data/angelica_buffs.gd (setzt die Welt); Tooltip: Text des Effekts und Restzeit
#   Win_QuickBar0/1  Schnellleisten (0 unten, 1 rechts, je 10 Plätze Sc_1..10 mit Fertigkeiten), EXP-Balken
#                    Pro_Exp (EXP / EXP bis zur Stufe)
#   Win_BaseSkill    Fertigkeiten (K / Knopf): 15 je Seite (Cmd_01.. Symbol, Txt_01.. Name und Stufe), Tooltip mit
#                    der Beschreibung (SkillDesc, Kontext Fenster), Ziehen in eine Schnellleiste
#   Win_NewSKill     neu gelernte Fertigkeiten (Img_Skill1..16, wie CDlgSkill_learnNew): zum Ziehen in die
#                    Leisten; gezogene und beim Schließen alle gelten als weggelegt (skill_seen)
#   Schnellleisten: Ziehen zwischen Plätzen tauscht, aus der Leiste heraus leert; Tooltip (Kontext Leiste);
#                    Tasten 1 - 0 bzw. Linksklick setzen die Fertigkeit ein (Signal skill_use_requested);
#                    Abklingzeit-Uhr (CoolOverlay, Meldung cooldown) auf Leisten und K-Fenster, Symbol
#                    dunkler ohne genug Mana; Zauberbalken: Win_Prgs mit dem Namen der Fertigkeit
#   Win_Chat         Eingabe "Sagen": Enter öffnet und sendet, Esc schließt
#   Win_ChatInfo     Verlauf (Name: Text; Meldungen des Systems rot), höchstens CHAT_LINES Zeilen
#   Win_MiniMap      Kartenbild um die eigene Figur (Lua InstanceWorld.lua: Instance[Welt][0] MiniMap /
#                    rectMap; 512 m * MapZoom 0,5 Durchmesser wie DEFAULT_RADAR_DIAMETER), rund maskiert
#                    (InGame\MiniMapMask.tga), Pfeil der Figur (InGame\MiniMapDir.tga), NPCs, Monster
#                    und Spieler als Marken (InGame\MiniMapMark\*.tga), Ziel der Autoroute (AutoMove.tga);
#                    Linksklick auf die Karte = Autoroute dorthin (Signal map_route_requested); Name der
#                    Map aus InstanceStr.lua.
#                    Die Maps behalten die Angelica-Koordinaten, in Godot ist die Welt dadurch gespiegelt
#                    (Blick nach +Z: +X links): Bild und Marken sind deshalb waagrecht gespiegelt, damit
#                    die Minimap zur sichtbaren Welt passt
#   Win_Inventory    Inventar (B oder Knopf "Inventar", CDlgInventory): Plätze Item_00 - 47 (ab der Größe
#                    der Tasche gesperrt), Symbole mit Anzahl, Geld (Diamant / Gold / Silber / Kupfer wie
#                    SetMoneyTextCtrl), Belegung; Rechtsklick legt Ausrüstung an, Ziehen verschiebt bzw.
#                    legt an (auf einen Platz im Charakter-Fenster); Tooltip mit Werten (item_data.gd)
#   Win_Character    Charakter (C oder Knopf "Figur", CDlgCharacter): Ausrüstungsplätze Equip_NN (NN =
#                    EQUIP_INDEX_*), Rechtsklick / Ziehen in die Tasche legt ab; Name, Klasse und Stufe,
#                    Leben / Mana, Angriff, Verteidigung, Treffer, Ausweichen, Krit-Werte (stats.attr des
#                    Servers); 3D-Bild der Figur mit Ausrüstung (char_preview.gd, Ziehen dreht)
#   Win_Prgs         Fortschritt beim Sammeln (Text des Sammelpunkts) und beim Zaubern (Name der Fertigkeit)
#   Win_Message4     "Ihr seid gestorben!" (CDlgRevive): Wiederbeleben (Btn_Decide, am nächsten Punkt) -
#                    Signal revive_requested; die übrigen Arten (durch andere, mit Gegenstand, perfekt)
#                    gibt es noch nicht
#   Win_QuestMinion  Quest-Verfolgung (CDlgTask "Win_QuestMinion"): je Quest Titel, laufender Teil,
#                    Ziel; NPC-Namen grün unterstrichen als Link (Klick = Autoroute, Signal
#                    route_npc_requested), Klick auf den Titel öffnet links daneben Win_QuestMinionDes
#                    (Ziel, Beschreibung, Belohnung), "-" / "+" klappt die Quest ein / aus. Statt der
#                    AUI-Baumansicht ein RichTextLabel an ihrer Stelle (die Godot-Baumansicht kennt keine
#                    Links im Text)
#   Win_Quest        Quest-Fenster (Q oder Knopf "Quest"): Tv_Quest mit den laufenden Quests, rechts
#                    (Win_QuestContent) Ziel (NPC als Link), Beschreibung und Belohnung, "Aufgeben"
#                    (nur mit giveup)
#   Win_NPC          NPC-Fenster (CDlgNPC): Gruß des NPCs, Quest-Einträge (quest_data.gd npc_entries)
#                    mit Symbol, "Gespräch beenden"; ein Eintrag zeigt sein Gespräch (talk_proc: Fenster
#                    mit Text und Optionen; Option = nächstes Fenster bzw. Sonderbefehl: Quest geben /
#                    abschließen / aufgeben -> Signal npc_option, zurück, beenden), "Zurück" zur Übersicht
#   Win_Main1 - 4    Leisten oben; Knopf "System" öffnet das Systemmenü, die übrigen melden im Chat,
#                    dass es sie noch nicht gibt
#   Win_Quit         Systemmenü (Esc): Wechseln = zurück zur Figurenauswahl, Verlassen = Spiel beenden,
#                    Zurück / Schließen, Fenster wechseln = anderer Skin, Einstellung (noch nicht da)
# Lage: wie in der Liste, dazu CECGameUIMan::RearrangeWindows: Ziel-Fenster rechts neben dem Kopf,
# Chatverlauf über der Eingabe; die Schnellleiste mit dem EXP-Balken unten in der Mitte (die
# v260-Quellen ordnen nur Skin 1, in Skin 2 steht sie in der Liste mittig).
# Ausgeblendet wird, was das Spiel ohne die zugehörigen Systeme verbirgt (Hilfe-Pfeile, Effekte, Glaube
# Shen / Mo, VIP, Werbung, Belohnungen ...): HIDE_RE für alle Dialoge, HIDE je Dialog.
# Tasten (world_screen.gd fragt handle_key): Enter Chat, Esc schließt Chat / Ziel / Systemmenü bzw.
# öffnet es, Tab nächstes Monster, F1 eigene Figur, 1 - 0 untere Schnellleiste. Signale an world_screen.gd: target_requested,
# say_requested, leave_requested, quit_requested, skin_requested.
# ====================================================

const AuiManager = preload("ui/aui_manager.gd")
const Proto = preload("../common/protocol.gd")
const LUA = "res://addons/PWE-Manager/Data/angelica_lua.gd"
const FILES = "res://addons/PWE-Manager/Data/angelica_files.gd"
const SHOWN = ["CharHead", "Chat", "ChatInfo", "MiniMap", "QuickBar0", "QuickBar1", "WinMain1", "WinMain3",
	"WinMain4", "QuestMinion", "Buff"]
const TARGETS = {"monster": "TargetMonster", "npc": "TargetNPC", "player": "TargetPlayer"}
const MENU = "Quit"
const NPC = "NPC"
const QUEST = "Quest"
const QUEST_DES = "QuestMinionDes"
const INVENTORY = "Inventory"
const CHARACTER = "Character"
const PROGRESS = "Progress"
const REVIVE = "Message4"
const SKILLS = "BaseSkill" # Win_BaseSkill (K)
const NEW_SKILLS = "Skill_LearnNew" # Win_NewSKill
const SKILL_SLOTS = 15
const NEW_SLOTS = 16
const BAR_DIALOGS = ["QuickBar0", "QuickBar1"] # Leiste 0 unten, 1 rechts
const BAR_SLOTS = 10
const BUFF = "Buff" # Win_Buff
const BUFF_SLOTS = 40 # Img_Buff0 - 39 (CDlgBuff BUFF_COUNT)
const BUFF_PER_LINE = 10
const TARGET_BUFF_SLOTS = 8 # st_1..8 / debuff_1..8 (CDLGTARGET_ST_MAX)
const LONG_BUFF_MINUTES = 30 # Stärkungen ab dieser Gesamtdauer zählen in Img_Buff0
const BUFF_RED_SECONDS = 30 # Restzeit darunter rot
const BUFF_REFRESH = 0.25 # s
const BUFF_TYPE_BUFF = 0 # SKILL_BUFF_TYPE_* (angelica_buffs.gd)
const BUFF_TYPE_DEBUFF = 1
const BUFF_TYPE_BUFF_NO_TIME = 3
const BUFF_TYPE_DEBUFF_NO_TIME = 4
const CharPreview = preload("char_preview.gd")
const BAG_SLOTS = 48 # Item_00 - 47
const EQUIP_SLOTS = 29 # Equip_00 - 28
const STF_CLASS = 101 # + Klasse, Texttabelle loginui (gameui hat dort nur Chinesisch)
const SLOT_LOCKED = Color(0, 0, 0, 0.55)
const LINK_COLOR = "#00ff00" # Koordinaten-Links (enumEICoord) grün unterstrichen
const TRACE_TITLE_HEX = "#ffdb59" # Quest-Titel in der Verfolgung
const NPC_GIVE_TASK = 0x80000006
const NPC_COMPLETE_TASK = 0x80000007
const TALK_RETURN = 0x80000011
const TALK_EXIT = 0x80000012
const TALK_GIVEUP_TASK = 0x80000015
const STF_END_TALK = 503 # "Gespräch beenden" (CDlgNPC::PopupNPCDialog)
const INFO_COLOR = "ffff00"
const BOOK_TITLE = Color(0.45, 0.2, 0.0) # Quest-Buch: dunkle Schrift auf Pergament
const BOOK_COLORS = {"title": "6e2f00", "part": "2a1a0a", "goal": "1d5c1d", "award": "6e2f00", "link": "#0a8f0a"} # Pergament
const TRACE_MAX = 25
const HIDE_RE = "(?i)(help|arrow|^gfx|^img_gfx|_gfx|(_shen|_mo)$|^skillnew_|promotion|^img_pk_|^txt_pk_|^img_icon_\\d|facebook|weibo|rune|pvpsoul|^txt_lowhp|^edt_expredeem|^txt_gua$|^pic_prof\\w*_(dark|light)$)"
const HIDE = {
	"CharHead": ["Btn_Add", "Img_TalentAdd", "Img_Combat_Fight", "Img_Combat_Rest", "Btn_Exp", "Img_Monster",
		"Chk_Optimize", "Img_Server", "Img_Server_1", "Btn_VIP", "Pic_Prof0_Dark", "Pic_Prof0_Light", "Pro_Soul_1",
		"Pro_Soul_2", "Pro_Soul_3", "Pro_Soul_4", "Pro_Soul_5", "Pro_Soul_6", "Txt_LowHP2", "Btn_HuoDong"],
	"TargetMonster": ["Img_MonsterLevel4", "Img_MonsterPetType1", "Img_MonsterPetType2", "Img_MonsterPetType3",
		"Edt_EggHelp", "Txt_EggHelp", "Txt_EggHelp2", "Txt_EggHelp3", "Edt_EggArrow", "Img_MonsterTrueLevel"],
	"TargetNPC": ["Img_MonsterLevel4"],
	"TargetPlayer": ["Prg_Stun", "Img_Belief", "Img_VIP", "Btn_GuildBattle"],
	"QuickBar0": ["Img_Godback", "Img_God", "Pro_Exp2", "Pro_Exp3", "Img_Exppass"],
	"MiniMap": ["Dlg_Back_TaiWan", "Edt_HideModelBack", "Btn_Radio", "Btn_Lua", "Btn_New", "Btn_Back", "Img_Mail",
		"Btn_Ranking", "Btn_Daily"],
	"WinMain3": ["Edt_GainPoint", "Img_GainPointMouse", "Txt_TimeTable", "Txt_GuildContent", "Edt_GuildFrame",
		"Txt_GainEquip2", "Edt_GainEquip", "Txt_GainEquip1", "Txt_GainPoint1", "Txt_GainPoint2", "Btn_Gift_Lua",
		"Img_GainEquipMouse", "Txt_Team", "Txt_Skill", "Btn_Team_2", "Btn_Pet_Work"],
	"Buff": ["Img_Korea_Logo_1", "Img_Korea_Logo_2", "Img_Captivation"], # Korea-Hinweis, Jugendschutz (TickWallow aus)
	"QuestMinion": ["Img_Alpha", "Img_Alpha1"], # Hintergrund mit einstellbarer Deckkraft (iTaskAlphaOption 0)
	"WinMain4": ["Img_AstrologyReverse", "Img_Combat_as01", "Img_Combat_as02", "Img_Combat_as03", "Img_Combat_as04"],
	"Quest": ["Btn_SearchQuest", "Btn_Focus", "Txt_AutoHelp3", "Txt_AutoHelp2", "Btn_Delete", "Chk_Tree",
		"Chk_FocusAll", "Btn_FindTask", "Btn_FindTask_1", "Lab_Guid", "Img_Guid"],
	"Inventory": ["Rdo_TaskItem", "Rdo_BusinessItem", "Btn_Booth", "Btn_Arrange", "Btn_Seperate", "Btn_Destroy",
		"Lab_Expand", "Scl_Item", "Img_FrameRealMoney", "Txt_RealMoney", "Lab_BindMoney", "Txt_BindMoney0",
		"Txt_BindMoney1", "Txt_BindMoney2", "Txt_BindMoney3", "Img_FrameBindMoney", "Img_FrameBindMoney_Back_1",
		"Img_FrameBindMoney_Back", "Edt_Back", "Txt_GainSth", "Img_Packfull", "Edt_PackFull", "Txt_PackFull", "Btn_Setting",
		"Btn_Lock", "Btn_Lua", "Btn_Storage", "Btn_QShopPack", "Img_FrameRealMoney_Bound", "Txt_RealMoney_Bound",
		"Rdo_Type1", "Rdo_Type2", "Rdo_Type3", "Rdo_Type4", "Rdo_Type5", "Rdo_Type6", "Rdo_Type7", "Rdo_Type8", "Line"],
	"Character": ["Img_Plate_Back", "Img_Soul_Back", "Equip_Plate_Back", "Equip_XP_Back", "Equip_Soul_Back_1",
		"Equip_Soul_Back_2", "Img_WereWolf_female", "Img_WereWolf_male", "Img_Titan", "Img_atomy_male",
		"Img_atomy_female", "Btn_LeftTurn", "Btn_RightTurn", "Rdo_03", "Rdo_04", "Rdo_05", "Rdo_Detail", "Rdo_FashDress",
		"Rdo_Equip", "Rdo_Reputation", "Rdo_Achieve", "Chk_HideHead", "Chk_HideHand", "Rdo_Equip_Fashion_1",
		"Rdo_Equip_Fashion_2", "Img_Star", "Txt_constellation", "Img_PK", "Txt_PK", "Btn_Ranklist", "Prgs_Vitality",
		"Prgs_Vigour", "Txt_Vigour", "Txt_Vitality", "Lab_Vigour", "Lab_Vitality", "Edt_VitalityBack", "Txt_Title",
		"Btn_Exp", "Btn_Achievement", "Btn_Credit", "Btn_PVP", "Btn_Marry", "Btn_Stone", "Btn_GOD", "Btn_Belial",
		"Lab_Belief_God", "Lab_Belief_Mo", "Lab_Belief_Value", "Txt_Belief_God", "Txt_Belief_Mo", "Txt_Belief_Value",
		"Edt_Belief_God", "Edt_Belief_Mo", "Edt_Belief_Value", "Prs_Belief_Value", "Lab_Energy", "Edt_EnergyBack",
		"Prgs_Energy", "Lab_FlyTime", "Txt_Energy", "Prgs_FlyTimeBack", "Edt_FlyTimeBack", "Txt_FlyTimeBack", "Img_Fly",
		"Txt_Fly", "Edt_VigourBack", "Lab_Hint_1", "Lab_Hint_2", "Btn_Vitality", "Btn_Vigour", "Btn_Equip_Soul_1",
		"Btn_Equip_Soul_2", "Btn_XP_Equip", "Rdo_Equip_Fashion_3", "Btn_ChangeEquip", "Rdo_Pet", "Rdo_Other", "Rdo_Kingdom",
		"Img_Prof_Dark", "Img_Prof_Light", "Equip_28"],
	"BaseSkill": ["Rdo_SkillScience", "Rdo_Produce", "Rdo_Transfer", "Rdo_Tree", "Rdo_Belief"],
	"Message4": ["Btn_Accept", "Btn_Revive", "Btn_ReLive", "Txt_Time", "Prgs_Time", "Txt_Time_Storm", "Btn_Back"],
	"Quit": ["Lab_Dai_Exp", "Txt_Dai_Exp", "Img_1", "Img_2", "Img_3", "Lab_ShengYu_Exp", "Txt_ShengYu_Exp",
		"Lab_Total_Exp", "Txt_Total_Exp", "Lab_Info_1", "Lab_Info_2", "Edt_Back", "Prgs_Total", "Prgs_Dai",
		"Prgs_ShengYu", "Lab_Info", "Btn_BBS", "Title2", "Txt_Exp_Max", "DEFAULT_Exp", "Lab_1", "Slider_Exp",
		"Lab_Zero", "Txt_Number", "Txt_BindMoney0", "Txt_BindMoney1", "Txt_BindMoney2", "Txt_BindMoney3",
		"Img_FrameMoney_Back", "Img_FrameBindMoney", "Lab_Hotkey", "Lab_ExpRedeem", "Btn_Redeem", "Chk_Exchange",
		"Sub_Content", "Btn_Confirm", "Sub_Content2", "Img_Line", "Lab_BindMoney", "Title_Login"],
}
# Menü-Knöpfe der Leisten ohne Funktion (Win_Main3: DlgWinTop)
const MENU_BUTTONS = ["Btn_Team", "Btn_Friend", "Btn_Qshop", "Btn_SubProf", "Btn_Pet", "Btn_Guild",
	"Btn_Daily"]
const RADAR_DIAMETER = 512.0 # m bei MapZoom 1 (DlgMiniMap DEFAULT_RADAR_DIAMETER)
const MAP_ZOOM = 0.5 # Voreinstellung uils.fMapZoom
const MARKS = {"npc": "InGame\\MiniMapMark\\NPC.tga", "monster": "InGame\\MiniMapMark\\Monster.tga",
	"player": "InGame\\MiniMapMark\\TeamMate.tga", "target": "InGame\\MiniMapMark\\Target.tga",
	"route": "InGame\\MiniMapMark\\AutoMove.tga"}
const CHAT_LINES = 200
const CHAT_NAME_COLOR = "ffde5a"
const CHAT_TEXT_COLOR = "ffffff"
const SYSTEM_COLOR = "ff6a6a"
const NAME_COLOR = Color(1, 1, 1)
const TEXTS = {
	"Deu": {"skill_level": "Уровень умения %d", "not_yet": "Пока недоступно.", "self": "Вы", "end_talk": "Завершить разговор", "talk_to": "Поговорить с %s",
		"quest_new": "Новое задание: %s", "quest_done": "Задание выполнено: %s", "quest_failed": "Задание провалено: %s",
		"gain_exp": "Получено опыта: %d.", "gain_item": "Получен предмет: %s x%d", "gain_gold": "Получено монет: %d.",
		"level_up": "Достигнут уровень %d!", "done_mark": "(выполнено)", "quests_title": "Задания",
		"desc": "Описание:", "goal": "Цель: %s", "award": "Награда: %s", "money": "%d монет",
		"route_start": "Автопуть к %s (%d м).", "route_failed": "Путь не найден (%s).",
		"route_stuck": "Автопуть остановлен: дальше пройти нельзя.", "route_far": "%s находится в другой области.",
		"route_unknown": "Местоположение %s неизвестно.", "map_point": "Точка на карте",
		"slots": ["Оружие", "Запястья", "Плечи", "Тело", "Пояс", "Ноги", "Голова", "Ступни", "Шея", "Дополнительное оружие",
			"Кольцо", "Кольцо"], "item_dmg": "Атака: %d–%d", "item_def": "Защита: %d", "item_hp": "Здоровье: +%d",
		"item_mp": "Мана: +%d", "item_hit": "Точность: +%d", "item_range": "Дальность: %.1f м", "item_lv": "Требуется уровень %d",
		"item_prof": "Класс: %s", "item_gender": "Пол: %s", "genders": ["мужской", "женский"],
		"item_race": "Ваша раса не может носить этот предмет", "item_pile": "Количество: %d / %d", "item_price": "Цена продажи: %d",
		"gather": "Сбор ресурсов", "gather_none": "Ничего не найдено.", "prof_level": "%s  Уровень %d", "bag_full_quest": "Инвентарь заполнен.",
		"races": ["", "Люди", "Эльфы", "Земные", "Каменные", "Киндреды", "Оборотни"], "miss": "Промах",
		"skill_stopped": "Использование умения прервано.", "buff_time": ["%d ч", "%d мин", "%d с"], "buff_left": "Осталось: %s"},
	"Eng": {"skill_level": "Level %d", "not_yet": "Not available yet.", "self": "You", "end_talk": "End conversation", "talk_to": "Talk to %s",
		"quest_new": "New quest: %s", "quest_done": "Quest completed: %s", "quest_failed": "Quest failed: %s",
		"gain_exp": "You receive %d EXP.", "gain_item": "You receive: %s x%d", "gain_gold": "You receive %d money.",
		"level_up": "You have reached level %d!", "done_mark": "(done)", "quests_title": "Quests",
		"desc": "Description:", "goal": "Goal: %s", "award": "Reward: %s", "money": "%d money",
		"route_start": "Auto route to %s (%d m).", "route_failed": "No path found (%s).",
		"route_stuck": "Auto route stopped: cannot get through here.", "route_far": "%s is in another area.",
		"route_unknown": "The location of %s is unknown.", "map_point": "map point",
		"slots": ["Weapon", "Wrist", "Shoulders", "Body", "Waist", "Legs", "Head", "Feet", "Neck", "Off-hand", "Ring",
			"Ring"], "item_dmg": "Attack: %d - %d", "item_def": "Defense: %d", "item_hp": "Health: +%d", "item_mp": "Mana: +%d",
		"item_hit": "Accuracy: +%d", "item_range": "Range: %.1f m", "item_lv": "Requires level %d", "item_prof": "Class: %s",
		"item_gender": "Gender: %s", "genders": ["male", "female"], "item_race": "Your race cannot wear this",
		"item_pile": "Count: %d / %d", "item_price": "Sell value: %d", "gather": "Gathering", "gather_none": "Nothing found.",
		"prof_level": "%s  Level %d", "bag_full_quest": "Your inventory is full.",
		"races": ["", "Human", "Elf", "Dwarf", "Stoneman", "Kindred", "Lycan"], "miss": "Miss",
		"skill_stopped": "Skill interrupted.", "buff_time": ["%d h", "%d m", "%d s"], "buff_left": "Time left: %s"},
	"Franz": {"skill_level": "Niveau %d", "not_yet": "Pas encore disponible.", "self": "Vous", "end_talk": "Terminer la conversation",
		"talk_to": "Parlez à %s", "quest_new": "Nouvelle quête : %s", "quest_done": "Quête accomplie : %s",
		"quest_failed": "Quête échouée : %s", "gain_exp": "Vous recevez %d EXP.", "gain_item": "Vous recevez : %s x%d",
		"gain_gold": "Vous recevez %d pièces.", "level_up": "Vous avez atteint le niveau %d !", "done_mark": "(accomplie)",
		"quests_title": "Quêtes", "desc": "Description :", "goal": "Objectif : %s", "award": "Récompense : %s",
		"money": "%d pièces", "route_start": "Itinéraire automatique vers %s (%d m).",
		"route_failed": "Aucun chemin trouvé (%s).", "route_stuck": "Itinéraire interrompu : passage impossible.",
		"route_far": "%s se trouve dans une autre zone.", "route_unknown": "La position de %s est inconnue.",
		"map_point": "point de la carte",
		"slots": ["Arme", "Poignets", "Épaules", "Torse", "Taille", "Jambes", "Tête", "Pieds", "Cou", "Main gauche",
			"Bague", "Bague"], "item_dmg": "Attaque : %d - %d", "item_def": "Défense : %d", "item_hp": "PV : +%d",
		"item_mp": "PM : +%d", "item_hit": "Précision : +%d", "item_range": "Portée : %.1f m", "item_lv": "Niveau requis %d",
		"item_prof": "Classe : %s", "item_gender": "Sexe : %s", "genders": ["masculin", "féminin"],
		"item_race": "Votre race ne peut pas porter cet objet", "item_pile": "Nombre : %d / %d",
		"item_price": "Valeur de vente : %d", "gather": "Récolte", "gather_none": "Rien trouvé.", "prof_level": "%s  Niveau %d",
		"bag_full_quest": "Votre inventaire est plein.",
		"races": ["", "Humain", "Elfe", "Nain", "Homme de pierre", "Kindred", "Lycan"], "miss": "Raté",
		"skill_stopped": "Compétence interrompue.", "buff_time": ["%d h", "%d m", "%d s"], "buff_left": "Temps restant : %s"},
}
const RADAR_SHADER = """
shader_type canvas_item;
uniform sampler2D map_tex : filter_linear, repeat_disable;
uniform sampler2D mask_tex : filter_linear;
uniform vec2 center = vec2(0.5);
uniform vec2 half_size = vec2(0.25);
uniform bool has_map = true;
void fragment() {
	vec2 uv = center + (UV - vec2(0.5)) * 2.0 * half_size;
	vec4 c = vec4(0.05, 0.08, 0.1, 1.0);
	if (has_map && uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
		c = texture(map_tex, uv);
	}
	COLOR = vec4(c.rgb, texture(mask_tex, UV).a);
}
"""

signal target_requested(id: int)
signal say_requested(text: String)
signal leave_requested
signal quit_requested
signal skin_requested(skin: int)
signal npc_option(command: int, task: int) # NPC_GIVE_TASK / NPC_COMPLETE_TASK / TALK_GIVEUP_TASK
signal npc_closed
signal quest_abandon_requested(id: int)
signal route_npc_requested(tid: int) # NPC-Link angeklickt
signal map_route_requested(world: Vector2) # Klick auf die Minimap (x, z)
signal pos_route_requested(goal: Vector3, world_id: int, label: String) # Koordinaten-Link (&pos:...&)
signal equip_requested(pos: int) # Taschenplatz anlegen
signal unequip_requested(slot: int, pos: int) # Ausrüstungsplatz ablegen (pos -1 = erster freier)
signal move_item_requested(from: int, to: int)
signal revive_requested
signal shortcut_requested(bar: int, slot: int, id: int) # Platz einer Schnellleiste belegen (id 0 = leeren)
signal skills_seen_requested(ids: Array) # aus "Neue Fertigkeiten" weggelegt
signal skill_use_requested(id: int) # Taste 1 - 0 oder Klick auf einen Platz einer Schnellleiste

# Abklingzeit-Uhr über einem Fertigkeiten-Platz (wie EC_ClockIcon): dunkles Tortenstück für die
# restliche Zeit, im Uhrzeigersinn ablaufend; ohne genug Mana ist das Symbol dunkler
class CoolOverlay extends Control:
	var hud
	var _left = -1.0
	var _dim = false
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true
	func _process(_delta: float) -> void:
		var id = int(get_parent().get_meta("skill", 0))
		var f = hud.cool_fraction(id) if id != 0 else 0.0
		if absf(f - _left) > 0.002 or (f == 0.0 and _left != 0.0):
			_left = f
			queue_redraw()
		var dim = id != 0 and not hud.mana_ok(id)
		if dim != _dim:
			_dim = dim
			var sym = get_parent().get_node_or_null("Symbol")
			if sym != null:
				sym.modulate = Color(0.45, 0.45, 0.55) if dim else Color.WHITE
	func _draw() -> void:
		if _left <= 0.0:
			return
		var c = size / 2.0
		var r = size.length()
		var pts = PackedVector2Array([c])
		var a0 = -PI / 2.0 + (1.0 - _left) * TAU
		var n = maxi(2, int(_left * 32))
		for i in n + 1:
			var a = a0 + (TAU - (a0 + PI / 2.0)) * i / n
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		var box = PackedVector2Array([Vector2.ZERO, Vector2(size.x, 0), size, Vector2(0, size.y)])
		for poly in Geometry2D.intersect_polygons(pts, box):
			draw_colored_polygon(poly, Color(0, 0, 0, 0.6))

# Marken auf der Minimap (Position im Radar, Art)
class RadarMarks extends Control:
	var marks: Array = [] # [Vector2, Texture2D]
	func _draw() -> void:
		for m in marks:
			var tex: Texture2D = m[1]
			if tex != null:
				draw_texture(tex, m[0] - tex.get_size() / 2.0)

var aui: AuiManager
var skin = 2
var language = "Deu"
var dialogs = {} # Kurzname ("CharHead") -> aui_dialog.gd
var map_name = ""
var map_title = ""
var target_id = 0
var target_kind = ""
var stats = {} # name, level, class, hp, max_hp, mp, max_mp, exp, exp_next
var chat_lines: Array = []
var warnings: Array = []
var _hide_re = RegEx.new()
var _chat_edit: LineEdit
var _radar: ColorRect
var _radar_marks: RadarMarks
var _arrow: TextureRect
var _map_rect = Rect2() # Welt: x links, z oben, Breite, Höhe (nach unten = -z)
var _mark_tex = {}
var quest_text: Callable = func(t): return t # Platzhalter (quest_data.gd format_text), setzt die Welt
var npc_entries: Array = []
var npc_task = 0 # Quest des laufenden Gesprächs
var _npc_hello = ""
var _npc_talk = {} # talk_proc des laufenden Gesprächs, {} = Übersicht
var _npc_options: Array = [] # zur Liste: ["entry", Eintrag] / ["option", Option] / ["exit"]
var quest_entries: Callable = func(): return [] # quest_data.gd log_entries, setzt die Welt
var quest_list: Array = [] # Einträge des offenen Quest-Fensters
var quest_selected = 0
var trace_entries: Array = [] # Einträge der Verfolgung (quest_data.gd trace)
var trace_folded = {} # Quest -> true (eingeklappt)
var des_quest = 0 # Quest in Win_QuestMinionDes
var route_target = null # Vector3: Ziel der Autoroute (Minimap)
var _trace_label: RichTextLabel
var _radar_pos = Vector3.ZERO
var _radar_scale = 1.0
var items = null # item_data.gd (setzt die Welt)
var skills = null # Plugin Data/angelica_skills.gd: Namen, Beschreibungen, Symbole (setzt die Welt)
var skill_state = {"skills": {}, "new": [], "shortcuts": {}} # ID -> Stufe, [IDs], Vector2i(Leiste, Platz) -> ID
var skill_info = {} # "ID" -> Werte vom Server (mp, time, cool, ...; setzt die Welt)
var cooldowns = {} # ID -> [Ende ms, Dauer ms]
var buffs = null # Plugin Data/angelica_buffs.gd: Art, Symbol, Text der Statuseffekte (setzt die Welt)
var my_buffs: Array = [] # eigene Effekte [[ID, Stapel, Ende ms (0 = ohne Ende), Dauer ms, light]]
var target_buffs: Array = [] # Effekte des Ziels, gleiche Form
var _buff_lists = {} # Sammelplätze in Win_Buff: "long" / "more" / "more_debuff" -> Effekte
var _buff_hover = [] # [Art, Platz] unter der Maus (Tooltip mit laufender Restzeit)
var _buff_t = 0.0
var _skill_page = 0
var _new_page = 0
var _drag_shortcut = Vector2i(-1, -1) # aus einer Leiste gezogen: ohne Ziel leeren
var me = {} # eigene Figur für Tooltips / Fenster: {name, level, race, class, gender, appearance}
var inventory = {"size": 24, "bag": {}, "equip": {}} # Platz -> [ID, Anzahl] / Platz -> ID
var equip_models: Callable = func(_e): return {} # {Platz: ID} -> {Platz: Modellpfad} (setzt die Welt)
var preview # char_preview.gd (Charakter-Fenster, beim ersten Öffnen gebaut)
var _data_root = ""
var _login_strings = {}
var _tooltip: PanelContainer
var _tooltip_text: RichTextLabel
var _preview_rect: TextureRect


# -> "" oder Fehlertext
func setup(data_root: String, p_language: String, p_skin: int, p_map: String, world_id: int) -> String:
	name = "HUD"
	language = p_language
	_data_root = data_root
	map_name = p_map
	_hide_re.compile(HIDE_RE)
	aui = AuiManager.new()
	aui.name = "HUD-Oberfläche"
	aui.keys_enabled = false
	add_child(aui)
	var err = aui.setup(data_root, language)
	if err != "":
		return err
	skin = p_skin
	if aui.load_layout("%dgameui" % skin) == 0:
		skin = 3 - skin
		if aui.load_layout("%dgameui" % skin) == 0:
			return "Не найден список диалогов gameui"
	for short in SHOWN + TARGETS.values() + [MENU, NPC, QUEST, QUEST_DES, INVENTORY, CHARACTER, PROGRESS, REVIVE, SKILLS, NEW_SKILLS]:
		var d = aui.dialog("%d%s.xml" % [skin, short])
		if d == null:
			warnings.append("Не найден файл диалога %d%s.xml" % [skin, short])
			continue
		dialogs[short] = d
		_hide_items(short, d)
		# Knöpfe nehmen keinen Tastaturfokus (wie AUI): Tab / Enter / Esc bleiben beim Spiel
		for item in d._items.values():
			if item is BaseButton:
				item.focus_mode = Control.FOCUS_NONE
		d.command.connect(_on_command.bind(short))
	_arrange()
	for short in SHOWN:
		if dialogs.has(short):
			aui.show_dialog(dialogs[short])
	_setup_chat()
	close_chat.call_deferred() # DEFAULT_Txt_Speech bekäme sonst beim Zeigen den Fokus
	_setup_menu()
	_setup_npc()
	_setup_quest()
	_setup_trace()
	set_trace([])
	_login_strings = aui.ui.read_string_table("loginui")
	_setup_tooltip()
	_setup_inventory()
	_setup_character()
	_setup_skills()
	_setup_buffs()
	_read_map_data(data_root, world_id)
	_setup_minimap()
	for w in aui.warnings:
		warnings.append(w)
	return ""

func dlg(short: String):
	return dialogs.get(short)

func texts() -> Dictionary:
	return TEXTS.get(language, TEXTS["Deu"])

# Lage wie RearrangeWindows als Listen-Position (bleibt beim Ändern der Fenstergröße erhalten):
# unten bündig heißt y < -1, darüber liegende Fenster haben y = y des unteren - dessen Höhe
func _arrange() -> void:
	var q = dlg("QuickBar0")
	if q != null:
		q.layout_pos = Vector2i(-1, -2)
	var head = dlg("CharHead")
	if head != null:
		for short in TARGETS.values():
			if dialogs.has(short):
				dialogs[short].layout_pos = Vector2i(head.layout_pos.x + int(head.size.x), head.layout_pos.y)
	var below = dlg("Chat")
	for short in ["ChatInfo", "ChatInfo2"]:
		var d = dlg(short)
		if d != null and below != null and below.layout_pos.y < -1:
			d.layout_pos = Vector2i(below.layout_pos.x, below.layout_pos.y - int(below.size.y))
			below = d

func _hide_items(short: String, d) -> void:
	var hide: Array = HIDE.get(short, [])
	for item_name in d._items:
		if item_name in hide or _hide_re.search(item_name) != null:
			d.show_item(item_name, false)


# ====================================================
# EIGENE WERTE (Win_CharHead, Win_QuickBar0)
# ====================================================
func set_stats(s: Dictionary) -> void:
	stats.merge(s, true)
	if window_open(CHARACTER):
		refresh_character()
	if window_open(INVENTORY):
		refresh_inventory()
	var d = dlg("CharHead")
	if d != null:
		d.set_text("Txt_Name", str(stats.get("name", "")))
		d.set_color("Txt_Name", NAME_COLOR)
		d.set_text("Txt_Lv0", str(stats.get("level", 1)))
		var hp = int(stats.get("hp", 0))
		var max_hp = maxi(1, int(stats.get("max_hp", 1)))
		var mp = int(stats.get("mp", 0))
		var max_mp = maxi(1, int(stats.get("max_mp", 1)))
		d.set_progress("Prgs_HP", 100.0 * hp / max_hp)
		d.set_text("Txt_HP", "%d/%d" % [hp, max_hp])
		d.set_progress("Prgs_MP", 100.0 * mp / max_mp)
		d.set_text("Txt_MP", "%d/%d" % [mp, max_mp])
		d.set_frame("Pic_Prof0", int(stats.get("class", 1)) - 1)
		d.set_progress("Prgs_Xp", 0.0)
		d.set_text("Txt_XP", "0/100")
		d.set_frame("Img_Doubleexp", 0)
	var q = dlg("QuickBar0")
	if q != null:
		var nxt = int(stats.get("exp_next", 0))
		q.set_progress("Pro_Exp", 100.0 * int(stats.get("exp", 0)) / nxt if nxt > 0 else 100.0)


# ====================================================
# ZIEL (Win_TargetMonster / Win_TargetNPC / Win_TargetPlayer)
# ====================================================
# t: Antwort von "target" (kind, level, hp, max_hp, mp, max_mp); display_name / color vom Aufrufer
func show_target(t: Dictionary, display_name: String, color: Color) -> void:
	clear_target()
	target_id = int(t.get("id", 0))
	target_kind = str(t.get("kind", ""))
	var d = dlg(TARGETS.get(target_kind, ""))
	if d == null:
		return
	d.set_text("Txt_Name", display_name)
	d.set_color("Txt_Name", color)
	d.set_text("Txt_LV", str(t.get("level", "")))
	d.set_text("Lab_Level", str(t.get("level", ""))) # Win_TargetPlayer
	if t.has("class"):
		d.set_frame("Pic_Prof", int(t["class"]) - 1)
	d.set_progress("Prg_HP", 100.0 * int(t.get("hp", 0)) / maxi(1, int(t.get("max_hp", 1))))
	d.set_progress("Prg_MP", 100.0 * int(t.get("mp", 0)) / maxi(1, int(t.get("max_mp", 1))) if int(t.get("max_mp", 0)) > 0 else 0.0)
	aui.show_dialog(d)

# Leben / Mana des Ziels nach einem Treffer
func update_target(hp: int, max_hp: int) -> void:
	var d = dlg(TARGETS.get(target_kind, ""))
	if d != null and d.visible:
		d.set_progress("Prg_HP", 100.0 * hp / maxi(1, max_hp))

# "Ihr seid gestorben!" zeigen / schließen
func show_revive(on: bool) -> void:
	var d = dlg(REVIVE)
	if d == null:
		return
	if on:
		d_revive_enable(true)
		aui.show_dialog(d)
	else:
		aui.hide_dialog(d)

func revive_shown() -> bool:
	return window_open(REVIVE)

func d_revive_enable(on: bool) -> void:
	var d = dlg(REVIVE)
	if d != null:
		d.enable_item("Btn_Decide", on)

func clear_target() -> void:
	target_id = 0
	target_kind = ""
	for short in TARGETS.values():
		if dialogs.has(short):
			aui.hide_dialog(dialogs[short])
	target_buffs = []
	refresh_target_buffs()

func target_shown() -> bool:
	return target_id != 0


# ====================================================
# STATUSEFFEKTE (Win_Buff, st_ / debuff_ im Ziel-Fenster)
# ====================================================
func _setup_buffs() -> void:
	var d = dlg(BUFF)
	if d != null:
		for i in BUFF_SLOTS:
			_prep_buff(d.item("Img_Buff%d" % i), "own", i)
			var label = d.item("Txt_Time%d" % i)
			if label is Label:
				label.set_meta("color", label.get_theme_color("font_color"))
	for short in TARGETS.values():
		var td = dlg(short)
		if td == null:
			continue
		for i in TARGET_BUFF_SLOTS:
			_prep_buff(td.item("st_%d" % (i + 1)), "st", i)
			_prep_buff(td.item("debuff_%d" % (i + 1)), "debuff", i)
	refresh_buffs()
	refresh_target_buffs()

# Effekt-Platz: Bild des Dialogs merken (Sammelplätze zeigen es wieder), Stapelzahl unten rechts, Tooltip
func _prep_buff(c, kind: String, idx: int) -> void:
	if not c is TextureRect:
		return
	c.set_meta("default_tex", c.texture)
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	c.tooltip_text = "" # Hint ^Dialog:Win_Buff_Hint (Img_Buff0) zeigt hier der eigene Tooltip
	var stack = Label.new()
	stack.name = "Stack"
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stack.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	stack.add_theme_font_size_override("font_size", 10)
	stack.add_theme_constant_override("outline_size", 3)
	stack.add_theme_color_override("font_outline_color", Color.BLACK)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(stack)
	c.mouse_entered.connect(_on_buff_hover.bind(kind, idx))
	c.mouse_exited.connect(_on_buff_exit)

func set_buffs(list: Array) -> void:
	my_buffs = list
	refresh_buffs()

func set_target_buffs(list: Array) -> void:
	target_buffs = list
	refresh_target_buffs()

func _buff_type(e: Array) -> int:
	return buffs.type(int(e[0])) if buffs != null else -1

# Wie CDlgBuff::UpdateBuff: Stärkungen ab Platz 1 (Platz 0 = lange), bei mehr als 28 ist Platz 1 der Sammelplatz;
# Schwächungen ab der nächsten vollen Reihe, passen sie nicht, ist deren erster Platz der Sammelplatz
func refresh_buffs() -> void:
	var d = dlg(BUFF)
	if d == null:
		return
	for i in BUFF_SLOTS:
		_buff_slot(d, i, null)
		d.show_item("Img_Buff%d" % i, false)
		d.show_item("Txt_Time%d" % i, false)
	for n in ["Txt_Buff", "Txt_Debuff_1", "Txt_Debuff_2", "Txt_Debuff_3", "Img_Buff_Back_Sign_2", "Img_Buff_Back_Sign_3",
			"Img_Debuff_Back_Sign_2", "Img_Debuff_Back_Sign_3", "Img_Debuff_Back_Sign_4"]:
		d.show_item(n, false)
	for n in ["Img_Buff0", "Txt_Buff_Long", "Img_Buff_Back_Sign_1"]:
		d.show_item(n, true)
	_buff_lists = {"long": [], "more": [], "more_debuff": []}
	var short = []
	var debuffs = []
	for e in my_buffs:
		var t = _buff_type(e)
		if t == BUFF_TYPE_BUFF and (int(e[3]) / 1000 - 1) / 60 + 1 >= LONG_BUFF_MINUTES:
			_buff_lists["long"].append(e)
		elif t == BUFF_TYPE_BUFF or t == BUFF_TYPE_BUFF_NO_TIME:
			short.append(e)
		elif t == BUFF_TYPE_DEBUFF or t == BUFF_TYPE_DEBUFF_NO_TIME:
			debuffs.append(e)
	_set_collector(d, 0, "long")
	var more = maxi(0, short.size() - (3 * BUFF_PER_LINE - 2))
	var slot = 1
	if more > 0:
		_buff_lists["more"] = short.slice(0, more)
		_set_collector(d, 1, "more")
		d.set_text("Txt_Buff", str(more))
		d.show_item("Txt_Buff", true)
		slot = 2
	for e in short.slice(more):
		_buff_slot(d, slot, e)
		slot += 1
	var first = 3 * BUFF_PER_LINE if more > 0 else (short.size() + BUFF_PER_LINE) / BUFF_PER_LINE * BUFF_PER_LINE
	var more_d = maxi(0, debuffs.size() - (BUFF_SLOTS - first - 1))
	slot = first
	if more_d > 0:
		_buff_lists["more_debuff"] = debuffs.slice(0, more_d)
		_set_collector(d, first, "more_debuff")
		d.set_text("Txt_Debuff_%d" % (first / BUFF_PER_LINE), str(more_d))
		d.show_item("Txt_Debuff_%d" % (first / BUFF_PER_LINE), true)
		slot = first + 1
	for e in debuffs.slice(more_d):
		_buff_slot(d, slot, e)
		slot += 1
	# Zeichen Stärkung / Schwächung rechts neben den Reihen
	var nd = debuffs.size()
	match first:
		10:
			d.show_item("Img_Debuff_Back_Sign_2", nd > 0)
			d.show_item("Img_Debuff_Back_Sign_3", nd > 10)
			d.show_item("Img_Debuff_Back_Sign_4", nd > 20)
		20:
			d.show_item("Img_Buff_Back_Sign_2", true)
			d.show_item("Img_Debuff_Back_Sign_3", nd > 0)
			d.show_item("Img_Debuff_Back_Sign_4", nd > 10)
		30:
			d.show_item("Img_Buff_Back_Sign_2", true)
			d.show_item("Img_Buff_Back_Sign_3", true)
			d.show_item("Img_Debuff_Back_Sign_4", nd > 0)
	d.set_text("Txt_Buff_Long", str(_buff_lists["long"].size()))
	_update_buff_times()

# Sammelplatz: Bild des Dialogs (Buff_Long / Buff_More / Debuff_More), Liste im Tooltip
func _set_collector(d, i: int, list: String) -> void:
	_buff_slot(d, i, null)
	var c = d.item("Img_Buff%d" % i)
	if c != null:
		c.set_meta("list", list)
		c.visible = true

# Platz i mit Effekt e (null = leeren); ohne Symbol bleibt er leer (CDlgBuff::SetBuff)
func _buff_slot(d, i: int, e) -> void:
	var c = d.item("Img_Buff%d" % i) as TextureRect
	var label = d.item("Txt_Time%d" % i)
	if c == null:
		return
	if label != null:
		label.set_meta("buff", null)
	c.remove_meta("list")
	if not _fill_buff(c, e):
		return
	c.visible = true
	var t = _buff_type(e)
	if label != null and (t == BUFF_TYPE_BUFF or t == BUFF_TYPE_DEBUFF):
		label.set_meta("buff", e)
		label.visible = true

# Symbol und Stapel eines Effekt-Platzes; false = leer (kein Effekt oder kein Symbol)
func _fill_buff(c: TextureRect, e) -> bool:
	var tex = buffs.icon(int(e[0])) if e != null and buffs != null else null
	var stack = c.get_node_or_null("Stack") as Label
	c.texture = tex if tex != null else c.get_meta("default_tex", null)
	c.set_meta("buff", e if tex != null else null)
	if stack != null:
		stack.text = str(int(e[1])) if tex != null and int(e[1]) > 1 else ""
	return tex != null

# Wie CDlgTarget: Stärkungen in st_1..8, Schwächungen in debuff_1..8 des sichtbaren Ziel-Fensters
func refresh_target_buffs() -> void:
	for short in TARGETS.values():
		var d = dlg(short)
		if d == null:
			continue
		var list = target_buffs if TARGETS.get(target_kind, "") == short else []
		for kind in ["st", "debuff"]:
			var j = 0
			for e in list:
				if j >= TARGET_BUFF_SLOTS:
					break
				var t = _buff_type(e)
				if (t == BUFF_TYPE_BUFF or t == BUFF_TYPE_BUFF_NO_TIME) if kind == "st" else (t == BUFF_TYPE_DEBUFF or t == BUFF_TYPE_DEBUFF_NO_TIME):
					var c = d.item("%s_%d" % [kind, j + 1])
					if c is TextureRect:
						_fill_buff(c, e)
					j += 1
			while j < TARGET_BUFF_SLOTS:
				var c = d.item("%s_%d" % [kind, j + 1])
				if c is TextureRect:
					_fill_buff(c, null)
				j += 1
	if not _buff_hover.is_empty() and _buff_hover[0] != "own":
		_on_buff_hover(_buff_hover[0], _buff_hover[1])

# Restzeit wie CDlgBuff::GetBuffTime -> [Text, rot]; ohne Ende / abgelaufen ""
func buff_time_text(end_ms: int) -> Array:
	if end_ms <= 0:
		return ["", false]
	var s = ceili((end_ms - Time.get_ticks_msec()) / 1000.0)
	if s <= 0:
		return ["", false]
	var f: Array = texts()["buff_time"]
	var text = f[0] % ((s - 1) / 3600 + 1) if s >= 3600 else (f[1] % ((s - 1) / 60 + 1) if s >= 60 else f[2] % s)
	return [text, s < BUFF_RED_SECONDS]

func _update_buff_times() -> void:
	var d = dlg(BUFF)
	if d == null:
		return
	for i in BUFF_SLOTS:
		var label = d.item("Txt_Time%d" % i) as Label
		if label == null or not label.visible or label.get_meta("buff", null) == null:
			continue
		var r = buff_time_text(int(label.get_meta("buff")[2]))
		d.set_text("Txt_Time%d" % i, r[0])
		label.add_theme_color_override("font_color", Color(1, 0, 0) if r[1] else label.get_meta("color", Color.WHITE))
	if not _buff_hover.is_empty():
		_on_buff_hover(_buff_hover[0], _buff_hover[1])

func _process(delta: float) -> void:
	_buff_t += delta
	if _buff_t >= BUFF_REFRESH:
		_buff_t = 0.0
		_update_buff_times()

# Platz-Control: own = Win_Buff Img_Buff<i>, st / debuff = Ziel-Fenster st_<i + 1> / debuff_<i + 1>
func buff_control(kind: String, idx: int) -> Control:
	if kind == "own":
		return dlg(BUFF).item("Img_Buff%d" % idx) if dlg(BUFF) != null else null
	var d = dlg(TARGETS.get(target_kind, ""))
	return d.item("%s_%d" % [kind, idx + 1]) if d != null else null

# Tooltip: Text des Effekts (buff_str) und Restzeit; Sammelplätze listen ihre Effekte mit Restzeit
func _on_buff_hover(kind: String, idx: int) -> void:
	_buff_hover = [kind, idx]
	var c = buff_control(kind, idx)
	if c == null or not c.is_visible_in_tree() or buffs == null:
		hide_tooltip()
		return
	var lines = []
	if c.has_meta("list"):
		for e in _buff_lists.get(str(c.get_meta("list")), []):
			lines.append("%s  %s" % [buffs.title(int(e[0])).replace("[", "[lb]"), buff_time_text(int(e[2]))[0]])
	elif c.get_meta("buff", null) != null:
		var e: Array = c.get_meta("buff")
		var text = buffs.desc(int(e[0]))
		lines.append(buffs.bbcode(text) if text != "" else str(int(e[0])))
		var left = buff_time_text(int(e[2]))[0]
		if left != "":
			lines.append(texts()["buff_left"] % left)
	if lines.is_empty():
		hide_tooltip()
		return
	show_tooltip("\n".join(lines))

func _on_buff_exit() -> void:
	_buff_hover = []
	hide_tooltip()


# ====================================================
# CHAT (Win_Chat, Win_ChatInfo)
# ====================================================
func _setup_chat() -> void:
	var d = dlg("Chat")
	if d == null:
		return
	_chat_edit = d.item("DEFAULT_Txt_Speech") as LineEdit
	if _chat_edit != null:
		_chat_edit.max_length = Proto.CHAT_MAX
		_chat_edit.gui_input.connect(_on_chat_input)
	var info = dlg("ChatInfo")
	if info != null:
		info.check_item("Btn_Set1", true)
		var content = info.item("Txt_Content")
		if content is RichTextLabel:
			content.scroll_following = true
		# Kanal der Eingabe: "Sagen" heißt im Verlauf wie der erste Reiter ("Normal")
		var way = d.item("Txt_Speakway")
		if way is OptionButton and info.get_text("Btn_Set1") != "":
			way.clear()
			way.add_item(info.get_text("Btn_Set1"))
			way.select(0)

func chat_focused() -> bool:
	return _chat_edit != null and _chat_edit.has_focus()

func open_chat() -> void:
	if _chat_edit != null:
		_chat_edit.grab_focus()

func close_chat() -> void:
	if _chat_edit != null:
		_chat_edit.release_focus()

func _on_chat_input(event: InputEvent) -> void:
	var k = event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
		_chat_edit.accept_event()
		close_chat()

func _send_chat() -> void:
	if _chat_edit == null:
		return
	var text = _chat_edit.text.strip_edges()
	_chat_edit.text = ""
	close_chat()
	if text != "":
		say_requested.emit(text)

# Nachricht eines Spielers im Verlauf
func add_chat(from_name: String, text: String) -> void:
	_add_line("^%s%s^%s: %s" % [CHAT_NAME_COLOR, _escape(from_name), CHAT_TEXT_COLOR, _escape(text)])

func add_system(text: String) -> void:
	_add_line("^%s%s" % [SYSTEM_COLOR, _escape(text)])

# Hinweis des Spiels (Quests, Belohnungen) in Gelb
func add_info(text: String) -> void:
	_add_line("^%s%s" % [INFO_COLOR, _escape(text)])

# Verlauf übernehmen (Skin-Wechsel)
func set_chat_lines(lines: Array) -> void:
	chat_lines = lines.duplicate()
	var info = dlg("ChatInfo")
	if info != null:
		info.set_text("Txt_Content", "\n".join(chat_lines))

func _add_line(line: String) -> void:
	chat_lines.append(line)
	if chat_lines.size() > CHAT_LINES:
		chat_lines = chat_lines.slice(chat_lines.size() - CHAT_LINES)
	var info = dlg("ChatInfo")
	if info != null:
		info.set_text("Txt_Content", "\n".join(chat_lines))

static func _escape(s: String) -> String:
	return s.replace("^", "^^")


# ====================================================
# SYSTEMMENÜ (Win_Quit)
# ====================================================
func _setup_menu() -> void:
	var d = dlg(MENU)
	if d != null:
		d.show_item("Title_Logout", true)

func menu_open() -> bool:
	return dialogs.has(MENU) and dialogs[MENU].visible

func open_menu() -> void:
	if dialogs.has(MENU):
		aui.show_dialog(dialogs[MENU])

func close_menu() -> void:
	if dialogs.has(MENU):
		aui.hide_dialog(dialogs[MENU])

func _on_command(cmd: String, short: String) -> void:
	match short:
		"Chat":
			if cmd == "speak":
				_send_chat()
		QUEST_DES:
			if cmd in ["Btn_Close", "IDCANCEL"]:
				close_des()
		SKILLS:
			match cmd:
				"Btn_Close", "IDCANCEL":
					close_window(SKILLS)
				"Btn_Back":
					_skill_page = maxi(0, _skill_page - 1)
					refresh_skills()
				"Btn_Next":
					_skill_page += 1
					refresh_skills()
		NEW_SKILLS:
			match cmd:
				"Btn_Close", "IDCANCEL":
					var ids: Array = skill_state["new"].duplicate()
					skills_seen(ids)
					if not ids.is_empty():
						skills_seen_requested.emit(ids)
				"Btn_PageDown":
					_new_page += 1
					refresh_new_skills()
				"Btn_PageUp":
					_new_page = maxi(0, _new_page - 1)
					refresh_new_skills()
		REVIVE:
			if cmd == "Btn_Decide":
				d_revive_enable(false)
				revive_requested.emit()
		INVENTORY:
			if cmd in ["Btn_Close", "IDCANCEL"]:
				close_window(INVENTORY)
		CHARACTER:
			if cmd in ["Btn_Close", "IDCANCEL"]:
				close_window(CHARACTER)
		QUEST:
			if cmd == "abandon" and quest_selected != 0:
				quest_abandon_requested.emit(quest_selected)
			elif cmd in ["IDCANCEL", "Btn_Close"]:
				close_quests()
		NPC:
			if cmd == "back":
				_npc_main()
			elif cmd in ["IDCANCEL", "Btn_Close", "Btn_Close2"]:
				close_npc()
		MENU:
			match cmd:
				"Btn_Return":
					close_menu()
					leave_requested.emit()
				"Btn_Quit":
					close_menu()
					quit_requested.emit()
				"Btn_Back", "Btn_Close", "IDCANCEL":
					close_menu()
				"Btn_ChangeUI":
					close_menu()
					skin_requested.emit(3 - skin)
				"Btn_Setting":
					add_system(texts()["not_yet"])
		"WinMain3":
			if cmd == "Btn_System":
				if menu_open():
					close_menu()
				else:
					open_menu()
			elif cmd == "Btn_Quest":
				toggle_quests()
			elif cmd == "Btn_Inventory":
				toggle_window(INVENTORY)
			elif cmd == "Btn_Character":
				toggle_window(CHARACTER)
			elif cmd == "Btn_Skill":
				toggle_window(SKILLS)
			elif cmd in MENU_BUTTONS:
				add_system(texts()["not_yet"])


# ====================================================
# NPC-FENSTER (Win_NPC mit Unterdialog Win_NPCContent: Txt_Content, Lst_Main)
# ====================================================
func _setup_npc() -> void:
	var d = dlg(NPC)
	if d == null:
		return
	d.show_item("Btn_Confirm", false)
	var list = d.item("Lst_Main") as ItemList
	if list != null:
		list.item_clicked.connect(_on_npc_click)
		list.item_activated.connect(_on_npc_list)
		list.focus_mode = Control.FOCUS_NONE

func npc_open() -> bool:
	return dialogs.has(NPC) and dialogs[NPC].visible

# NPC-Fenster: Name, Gruß, Einträge [{id, kind, talk, title, icon}]
func open_npc(npc_name: String, hello: String, entries: Array) -> void:
	var d = dlg(NPC)
	if d == null:
		return
	d.set_text("Txt_npc", npc_name)
	_npc_hello = hello
	npc_entries = entries
	_npc_main()
	aui.show_dialog(d)

func close_npc() -> void:
	if npc_open():
		aui.hide_dialog(dialogs[NPC])
		npc_closed.emit()

# Übersicht: Gruß, Quest-Einträge, "Gespräch beenden"
func _npc_main() -> void:
	var d = dlg(NPC)
	_npc_talk = {}
	npc_task = 0
	d.set_text("Txt_Content", _npc_hello)
	var list = d.item("Lst_Main") as ItemList
	list.clear()
	_npc_options = []
	for e in npc_entries:
		list.add_item(e["title"], e.get("icon"))
		_npc_options.append(["entry", e])
	list.add_item(_end_talk())
	_npc_options.append(["exit"])
	d.show_item("Btn_Back", false)

# Fenster win_id des laufenden Gesprächs (-1 = erstes)
func _npc_window(win_id: int) -> void:
	var wins: Array = _npc_talk.get("windows", [])
	var win = wins[0] if not wins.is_empty() else {}
	for w in wins:
		if int(w["id"]) == win_id:
			win = w
	var d = dlg(NPC)
	d.set_text("Txt_Content", quest_text.call(str(win.get("text", ""))))
	var list = d.item("Lst_Main") as ItemList
	list.clear()
	_npc_options = []
	for o in win.get("options", []):
		list.add_item(_plain(quest_text.call(str(o["text"]))))
		_npc_options.append(["option", o])
	if _npc_options.is_empty():
		list.add_item(_end_talk())
		_npc_options.append(["exit"])
	d.show_item("Btn_Back", true)

# "Gespräch beenden" aus der Texttabelle (503); dort steht in Deu / Eng / Franz noch "再见。"
func _end_talk() -> String:
	var end = aui.text(STF_END_TALK)
	var re = RegEx.new()
	re.compile("[\\x{3000}-\\x{9fff}]")
	return end if end != "" and re.search(end) == null else texts()["end_talk"]

func _on_npc_click(index: int, _at: Vector2, button: int) -> void:
	if button == MOUSE_BUTTON_LEFT:
		_on_npc_list(index)

func _on_npc_list(index: int) -> void:
	if index < 0 or index >= _npc_options.size():
		return
	var o: Array = _npc_options[index]
	match o[0]:
		"exit":
			close_npc()
		"entry":
			_npc_talk = o[1]["talk"]
			npc_task = int(o[1]["id"])
			_npc_window(-1)
		"option":
			var id = int(o[1]["id"])
			var param = int(o[1].get("param", 0))
			if id < 0x80000000:
				_npc_window(id)
			elif id == NPC_GIVE_TASK or id == NPC_COMPLETE_TASK or id == TALK_GIVEUP_TASK:
				npc_option.emit(id, param if param != 0 else npc_task) # die Welt merkt sich dabei den NPC
				close_npc() # wie CDlgNPC: nach dem Befehl zu (kein zweites Mal)
			elif id == TALK_RETURN:
				_npc_main()
			elif id == TALK_EXIT:
				close_npc()
			else:
				add_system(texts()["not_yet"])

# Farbcodes für die Liste entfernen (ItemList kennt keine)
static func _plain(s: String) -> String:
	var re = RegEx.new()
	re.compile("\\^([0-9a-fA-F]{6}|O\\d{3}|[a-zA-Z])")
	return re.sub(s, "", true)


# ====================================================
# QUEST-FENSTER (Win_Quest mit Unterdialog Win_QuestContent)
# ====================================================
func _setup_quest() -> void:
	var d = dlg(QUEST)
	if d == null:
		return
	d.set_text("Title", texts()["quests_title"])
	d.set_text("Lab_Desc", texts()["desc"])
	d.set_text("Title2", map_title)
	var tree = d.item("Tv_Quest") as Tree
	if tree != null:
		tree.item_selected.connect(func(): _show_quest(int(tree.get_selected().get_metadata(0))))
		tree.focus_mode = Control.FOCUS_NONE
	var head = d.item("Txt_QuestItem") as RichTextLabel
	if head != null:
		head.meta_clicked.connect(_on_link)
		head.meta_underlined = false
	for i in 4:
		d.show_item("Img_Item%d" % i, false)
	# Belohnungs-Bilder gibt es noch nicht: die Beschreibung bekommt ihren Platz
	var content = d.item("Txt_Content")
	var bottom = d.item("Img_Item0")
	if content != null and bottom != null:
		content.size.y = bottom.position.y + bottom.size.y - content.position.y

func quest_open() -> bool:
	return dialogs.has(QUEST) and dialogs[QUEST].visible

func toggle_quests() -> void:
	if quest_open():
		close_quests()
	else:
		open_quests()

func close_quests() -> void:
	if quest_open():
		aui.hide_dialog(dialogs[QUEST])

func open_quests() -> void:
	var d = dlg(QUEST)
	if d == null:
		return
	aui.show_dialog(d)
	refresh_quests()

# Liste neu (nach jeder Änderung, solange das Fenster offen ist)
func refresh_quests() -> void:
	var d = dlg(QUEST)
	if d == null or not d.visible:
		return
	quest_list = quest_entries.call()
	d.set_text("Txt_ShuLiang", "%d/%d" % [quest_list.size(), TRACE_MAX])
	var tree = d.item("Tv_Quest") as Tree
	tree.clear()
	var root = tree.create_item()
	var keep = null
	for e in quest_list:
		var it = tree.create_item(root)
		it.set_text(0, _plain(str(e["name"])))
		it.set_custom_color(0, BOOK_TITLE)
		it.set_metadata(0, e["id"])
		if str(e.get("part", "")) != "":
			var sub = tree.create_item(it)
			sub.set_text(0, _plain(str(e["part"])))
			sub.set_metadata(0, e["id"])
		if int(e["id"]) == quest_selected:
			keep = it
	if keep == null and root.get_child_count() > 0:
		keep = root.get_child(0)
	if keep != null:
		keep.select(0)
		_show_quest(int(keep.get_metadata(0)))
	else:
		_show_quest(0)

func _show_quest(id: int) -> void:
	var d = dlg(QUEST)
	quest_selected = id
	var e = {}
	for x in quest_list:
		if int(x["id"]) == id:
			e = x
	_set_rich(d.item("Txt_QuestItem"), _quest_head(e, BOOK_COLORS, true))
	var body = str(e.get("description", ""))
	if str(e.get("award", "")) != "":
		body += "\n\n^%s" % BOOK_COLORS["award"] + _escape(texts()["award"] % e["award"])
	d.set_text("Txt_Content", body)
	_link_markers(d.item("Txt_Content"), BOOK_COLORS["link"])
	d.enable_item("Btn_Abandon", e.get("giveup", false))


# ====================================================
# QUEST-VERFOLGUNG (Win_QuestMinion: Tv_TraceContent, Txt_ShuLiang) UND Win_QuestMinionDes
# ====================================================
# Text mit Links an der Stelle der Baumansicht (gleiche Schrift)
func _setup_trace() -> void:
	var d = dlg("QuestMinion")
	var tree = d.item("Tv_TraceContent") as Control if d != null else null
	if tree == null:
		return
	_trace_label = RichTextLabel.new()
	_trace_label.name = "Verfolgung"
	_trace_label.bbcode_enabled = true
	_trace_label.meta_underlined = false # nur NPC-Links sind unterstrichen ([u])
	_trace_label.position = tree.position
	_trace_label.size = tree.size
	_trace_label.scroll_active = true
	_trace_label.focus_mode = Control.FOCUS_NONE
	_trace_label.mouse_filter = Control.MOUSE_FILTER_PASS
	if tree.has_theme_font_override("font"):
		_trace_label.add_theme_font_override("normal_font", tree.get_theme_font("font"))
	if tree.has_theme_font_size_override("font_size"):
		_trace_label.add_theme_font_size_override("normal_font_size", tree.get_theme_font_size("font_size"))
	_trace_label.add_theme_color_override("default_color", Color(0.92, 0.92, 0.88))
	_trace_label.add_theme_constant_override("outline_size", 3)
	_trace_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_trace_label.meta_clicked.connect(_on_link)
	tree.get_parent().add_child(_trace_label)
	tree.visible = false
	var des = dlg(QUEST_DES)
	if des != null:
		for i in 4:
			des.show_item("Img_Item%d" % i, false)
		# Unterdialog (233 x 319) ist auf 215 Pixel Höhe abgeschnitten: Beschreibung bis dahin, rollbar
		var content = des.item("Txt_Content")
		var sub = des.item("Sub_Content")
		if content is RichTextLabel:
			content.size.y = (sub.size.y if sub != null else 215.0) - content.position.y
			content.scroll_active = true
		var head = des.item("Txt_QuestItem") as RichTextLabel
		if head != null:
			head.meta_clicked.connect(_on_link)
			head.meta_underlined = false

# entries: quest_data.gd trace() (id, name, part, goal, talk, npc, done)
func set_trace(entries: Array) -> void:
	trace_entries = entries
	var d = dlg("QuestMinion")
	if d == null:
		return
	d.set_text("Txt_ShuLiang", "%d/%d" % [entries.size(), TRACE_MAX])
	if _trace_label == null:
		return
	var lines = PackedStringArray()
	for e in entries:
		var id = int(e["id"])
		var folded = trace_folded.get(id, false)
		lines.append("[url=fold:%d]%s[/url] [url=quest:%d][color=%s]%s[/color][/url]" % [id, "+" if folded else "-", id,
			TRACE_TITLE_HEX, _bb(_plain(str(e["name"])))])
		if folded:
			continue
		if str(e.get("part", "")) != "":
			lines.append("   " + _bb(_plain(str(e["part"]))) + ((" " + texts()["done_mark"]) if e.get("done", false) else ""))
		if str(e.get("goal", "")) != "":
			var where: Array = e.get("where", [])
			lines.append("   " + _goal_bb(e) + ((" (%s)" % _pos_link(where, LINK_COLOR)) if not where.is_empty() else ""))
	_trace_label.text = "\n".join(lines)
	if des_open():
		_show_des(des_quest)

# Für Tests und Anzeige: je Quest [Titel, Teil, Ziel] als Text
func trace_items() -> Array:
	var out = []
	for e in trace_entries:
		var lines = [_plain(str(e["name"]))]
		if str(e.get("part", "")) != "":
			lines.append(_plain(str(e["part"])) + ((" " + texts()["done_mark"]) if e.get("done", false) else ""))
		if str(e.get("goal", "")) != "":
			lines.append(texts()["talk_to"] % e["goal"] if e.get("talk", false) else str(e["goal"]))
		out.append(lines)
	return out

# Ziel als BBCode, NPC als grüner Link
func _goal_bb(e: Dictionary, prefix: bool = false, link_color: String = LINK_COLOR) -> String:
	var goal = str(e.get("goal", ""))
	if goal == "":
		return ""
	var g = _bb(goal)
	if e.get("talk", false):
		var link = "[url=npc:%d][color=%s][u]%s[/u][/color][/url]" % [int(e.get("npc", 0)), link_color, g] if int(e.get("npc", 0)) != 0 else g
		g = texts()["talk_to"].replace("%s", link)
	return texts()["goal"].replace("%s", g) if prefix else g

# Kopf (Titel, Teil, Ziel mit Link) als BBCode für Win_Quest / Win_QuestMinionDes
func _quest_head(e: Dictionary, colors: Dictionary, prefix: bool) -> String:
	if e.is_empty():
		return ""
	var head = "[color=#%s]%s[/color]" % [colors["title"], _bb(_plain(str(e["name"])))]
	if str(e.get("part", "")) != "":
		head += "\n[color=#%s]%s[/color]" % [colors["part"], _bb(_plain(str(e["part"])))]
	if str(e.get("goal", "")) != "":
		head += "\n[color=#%s]%s[/color]" % [colors["goal"], _goal_bb(e, prefix, colors.get("link", LINK_COLOR))]
	return head

func _set_rich(c, bbcode: String) -> void:
	if c is RichTextLabel:
		c.text = bbcode

static func _bb(s: String) -> String:
	return s.replace("[", "[lb]")

# Koordinaten-Link [x, y, z, Welt, Name] als BBCode
static func _pos_link(p: Array, color: String) -> String:
	return "[url=pos:%s,%s,%s,%d:%s][color=%s][u]%s[/u][/color][/url]" % [p[0], p[1], p[2], int(p[3]), str(p[4]).uri_encode(), color,
		_bb(str(p[4]))]

# Marken von quest_data.gd format_text (Koordinaten-Links) im fertigen BBCode eines Textfelds ersetzen
func _link_markers(c, color: String) -> void:
	if not c is RichTextLabel or not c.text.contains("\uE000"):
		return
	var re = RegEx.new()
	re.compile("\uE000([^\uE001]*)\uE001([^\uE002]*)\uE002")
	var out = c.text
	for m in re.search_all(c.text):
		var n = m.get_string(1).split(",")
		if n.size() < 4:
			continue
		out = out.replace(m.get_string(0), _pos_link([n[0].to_float(), n[1].to_float(), n[2].to_float(), n[3].to_int(),
			m.get_string(2)], color))
	c.text = out
	if not c.meta_clicked.is_connected(_on_link):
		c.meta_clicked.connect(_on_link)
		c.meta_underlined = false

func _on_link(meta) -> void:
	var m = str(meta)
	var id = m.get_slice(":", 1).to_int()
	if m.begins_with("npc:"):
		route_npc_requested.emit(id)
	elif m.begins_with("pos:"):
		var parts = m.substr(4).split(":", true, 1)
		var n = parts[0].split(",")
		if n.size() >= 4:
			pos_route_requested.emit(Vector3(n[0].to_float(), n[1].to_float(), n[2].to_float()), n[3].to_int(),
				parts[1].uri_decode() if parts.size() > 1 else "")
	elif m.begins_with("fold:"):
		trace_folded[id] = not trace_folded.get(id, false)
		set_trace(trace_entries)
	elif m.begins_with("quest:"):
		if des_open() and des_quest == id:
			close_des()
		else:
			open_des(id)

func des_open() -> bool:
	return dialogs.has(QUEST_DES) and dialogs[QUEST_DES].visible

func close_des() -> void:
	if des_open():
		aui.hide_dialog(dialogs[QUEST_DES])

# Beschreibung einer Quest links neben der Verfolgung (CDlgTask::OnEventLButtonDown_Trace)
func open_des(id: int) -> void:
	var d = dlg(QUEST_DES)
	var minion = dlg("QuestMinion")
	if d == null or minion == null:
		return
	# rechts bündig wie die Verfolgung: linke Kante der Verfolgung = rechte Kante der Beschreibung
	var x = minion.layout_pos.x - int(minion.size.x) if minion.layout_pos.x < -1 else maxi(0, int(minion.position.x - d.size.x))
	d.layout_pos = Vector2i(x, maxi(0, int(minion.position.y)))
	_show_des(id)
	aui.show_dialog(d)

func _show_des(id: int) -> void:
	var d = dlg(QUEST_DES)
	des_quest = id
	var e = {}
	for x in quest_entries.call():
		if int(x["id"]) == id:
			e = x
	if e.is_empty():
		close_des()
		return
	_set_rich(d.item("Txt_QuestItem"), _quest_head(e, BOOK_COLORS, true)) # auch Pergament
	var body = str(e.get("description", ""))
	if str(e.get("award", "")) != "":
		body += "\n\n^%s" % BOOK_COLORS["award"] + _escape(texts()["award"] % e["award"])
	d.set_text("Txt_Content", body)
	_link_markers(d.item("Txt_Content"), BOOK_COLORS["link"])


# ====================================================
# TASTEN -> true, wenn verbraucht
# ====================================================
func handle_key(k: InputEventKey) -> bool:
	if aui.has_message_box():
		return false
	match k.keycode:
		KEY_Q:
			if not chat_focused():
				toggle_quests()
				return true
		KEY_B:
			if not chat_focused():
				toggle_window(INVENTORY)
				return true
		KEY_C:
			if not chat_focused():
				toggle_window(CHARACTER)
				return true
		KEY_K:
			if not chat_focused():
				toggle_window(SKILLS)
				return true
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0:
			if not chat_focused() and not k.ctrl_pressed and not k.alt_pressed:
				var id = skill_at("bar0", 9 if k.keycode == KEY_0 else k.keycode - KEY_1)
				if id != 0:
					skill_use_requested.emit(id)
				return true
		KEY_ENTER, KEY_KP_ENTER:
			if not chat_focused():
				open_chat()
				return true
		KEY_ESCAPE:
			if chat_focused():
				close_chat()
			elif npc_open():
				close_npc()
			elif quest_open():
				close_quests()
			elif window_open(INVENTORY) or window_open(CHARACTER) or window_open(SKILLS):
				close_window(INVENTORY)
				close_window(CHARACTER)
				close_window(SKILLS)
			elif des_open():
				close_des()
			elif menu_open():
				close_menu()
			elif target_shown():
				target_requested.emit(0)
			else:
				open_menu()
			return true
	return false


# ====================================================
# INVENTAR (Win_Inventory) UND CHARAKTER (Win_Character)
# ====================================================
func window_open(short: String) -> bool:
	return dialogs.has(short) and dialogs[short].visible

func toggle_window(short: String) -> void:
	if window_open(short):
		close_window(short)
	else:
		open_window(short)

func open_window(short: String) -> void:
	var d = dlg(short)
	if d == null:
		return
	aui.show_dialog(d)
	if short == CHARACTER:
		_show_preview()
		refresh_character()
	elif short == SKILLS:
		refresh_skills()
	else:
		refresh_inventory()

func close_window(short: String) -> void:
	if window_open(short):
		aui.hide_dialog(dialogs[short])
		hide_tooltip()
		if short == CHARACTER and preview != null:
			preview.set_active(false)

func class_name_of(c: int) -> String:
	return str(_login_strings.get(STF_CLASS + c, c))

func _setup_inventory() -> void:
	var d = dlg(INVENTORY)
	if d == null:
		return
	for item_name in d._items:
		var n = String(item_name)
		if n.begins_with("ItemNewGfx_") or n.begins_with("Img_Enhance") or n.to_lower().contains("fashdress"):
			d.show_item(n, false)
	for i in BAG_SLOTS:
		var c = d.item("Item_%02d" % i)
		if c != null:
			_prep_slot(c, "bag", i)
	var rdo = d.item("Rdo_NormalItem")
	if rdo is BaseButton:
		rdo.button_pressed = true

func _setup_character() -> void:
	var d = dlg(CHARACTER)
	if d == null:
		return
	for item_name in d._items:
		var n = String(item_name)
		if n.to_lower().contains("fashdress") or n.begins_with("Edt_Stone_") or n.begins_with("Prgs_Stone_") or n.begins_with("Txt_Grade") \
				or n.begins_with("Img_Enhance"):
			d.show_item(n, false)
	for i in EQUIP_SLOTS:
		var c = d.item("Equip_%02d" % i)
		if c != null and c.size.x > 4.0 and c.position.x >= 0.0 and c.position.x < d.size.x:
			_prep_slot(c, "equip", i)
	var area = d.item("Img_Male")
	if area != null:
		_preview_rect = TextureRect.new()
		_preview_rect.name = "Figur"
		_preview_rect.position = area.position
		_preview_rect.size = area.size
		_preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_preview_rect.stretch_mode = TextureRect.STRETCH_SCALE
		_preview_rect.mouse_filter = Control.MOUSE_FILTER_STOP
		_preview_rect.gui_input.connect(_on_preview_input)
		area.get_parent().add_child(_preview_rect)
		area.get_parent().move_child(_preview_rect, area.get_index() + 1)

# Platz vorbereiten: Symbol, Anzahl, Sperre; Maus (Rechtsklick, Tooltip, Ziehen)
func _prep_slot(c: Control, kind: String, idx: int) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	var icon = TextureRect.new()
	icon.name = "Symbol"
	icon.size = c.size
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(icon)
	var count = Label.new()
	count.name = "Anzahl"
	count.size = c.size - Vector2(3, 1)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.add_theme_font_size_override("font_size", 11)
	count.add_theme_constant_override("outline_size", 3)
	count.add_theme_color_override("font_outline_color", Color.BLACK)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(count)
	var lock = ColorRect.new()
	lock.name = "Sperre"
	lock.size = c.size
	lock.color = SLOT_LOCKED
	lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lock.visible = false
	c.add_child(lock)
	c.gui_input.connect(_on_slot_input.bind(kind, idx))
	c.mouse_entered.connect(_on_slot_hover.bind(kind, idx))
	c.mouse_exited.connect(hide_tooltip)
	c.set_drag_forwarding(_slot_drag.bind(kind, idx), _slot_can_drop.bind(kind, idx), _slot_drop.bind(kind, idx))

func _slot_control(kind: String, idx: int) -> Control:
	var d = dlg(INVENTORY if kind == "bag" else CHARACTER)
	return d.item(("Item_%02d" if kind == "bag" else "Equip_%02d") % idx) if d != null else null

func _set_slot(c: Control, id: int, count: int, locked: bool) -> void:
	if c == null or c.get_node_or_null("Symbol") == null:
		return
	(c.get_node("Symbol") as TextureRect).texture = items.icon(id) if id != 0 and items != null else null
	(c.get_node("Anzahl") as Label).text = str(count) if count > 1 else ""
	c.get_node("Sperre").visible = locked
	c.set_meta("item", id)

# Inventar vom Server ({size, bag: [[Platz, ID, Anzahl]], equip: [[Platz, ID]]})
func set_inventory(state: Dictionary) -> void:
	var bag = {}
	for e in state.get("bag", []):
		bag[int(e[0])] = [int(e[1]), int(e[2])]
	var equip = {}
	for e in state.get("equip", []):
		equip[int(e[0])] = int(e[1])
	var changed = equip != inventory["equip"]
	inventory = {"size": int(state.get("size", 24)), "bag": bag, "equip": equip}
	refresh_inventory()
	refresh_character()
	if changed and preview != null and preview.model != null:
		preview.set_equipment(equip_models.call(equip))

func bag_items() -> Array:
	var out = []
	var keys = inventory["bag"].keys()
	keys.sort()
	for pos in keys:
		out.append([pos, inventory["bag"][pos][0], inventory["bag"][pos][1]])
	return out

func refresh_inventory() -> void:
	var d = dlg(INVENTORY)
	if d == null:
		return
	for i in BAG_SLOTS:
		var e = inventory["bag"].get(i, [0, 0])
		_set_slot(d.item("Item_%02d" % i), e[0], e[1], i >= inventory["size"])
	d.set_text("Txt_BagNum", "%d/%d" % [inventory["bag"].size(), inventory["size"]])
	var m = int(stats.get("money", 0))
	d.set_text("Txt_Money3", str(m % 100))
	d.set_text("Txt_Money2", str((m / 100) % 100))
	d.set_text("Txt_Money1", str((m / 10000) % 100))
	d.set_text("Txt_Money0", str(m / 1000000))

func refresh_character() -> void:
	var d = dlg(CHARACTER)
	if d == null:
		return
	for i in EQUIP_SLOTS:
		var c = d.item("Equip_%02d" % i)
		if c != null and c.has_node("Symbol"):
			_set_slot(c, int(inventory["equip"].get(i, 0)), 1, false)
	var female = int(me.get("gender", 0)) == 1
	d.show_item("Img_Male", not female)
	d.show_item("Img_Female", female)
	d.set_text("Txt_Name", str(me.get("name", stats.get("name", ""))))
	var races: Array = texts()["races"]
	d.set_text("Txt_Race", races[clampi(int(me.get("race", 1)), 0, races.size() - 1)])
	d.set_text("Txt_Prof1", texts()["prof_level"] % [class_name_of(int(stats.get("class", me.get("class", 0)))), int(stats.get("level", 1))])
	d.set_frame("Img_Prof", int(stats.get("class", 1)) - 1)
	d.set_text("Txt_Hp", "%d/%d" % [int(stats.get("hp", 0)), int(stats.get("max_hp", 0))])
	d.set_text("Txt_Mp", "%d/%d" % [int(stats.get("mp", 0)), int(stats.get("max_mp", 0))])
	var a: Dictionary = stats.get("attr", {})
	var dmg: Array = a.get("dmg", [0, 0])
	d.set_text("Txt_Damage", "%d-%d" % [int(dmg[0]), int(dmg[1])])
	d.set_text("Txt_Defense", str(int(a.get("def", 0))))
	d.set_text("Txt_Definition", str(int(a.get("hit", 0))))
	d.set_text("Txt_Evade", str(int(a.get("eva", 0))))
	d.set_text("Txt_Block", "0")
	d.set_text("Txt_BlockDef", "0")
	d.set_text("Txt_Critical", "%.1f%%" % float(a.get("crit", 0.0)))
	d.set_text("Txt_CriticalDamage", "%d%%" % int(a.get("crit_dmg", 0)))
	d.set_text("Txt_DesCritical", "%.1f%%" % float(a.get("anti_crit", 0.0)))
	d.set_text("Txt_DesCriticalDamage", "%.1f%%" % float(a.get("anti_crit_dmg", 0.0)))

# 3D-Bild der Figur im Charakter-Fenster (beim ersten Öffnen gebaut)
func _show_preview() -> void:
	if _preview_rect == null:
		return
	if preview == null:
		preview = CharPreview.new()
		preview.name = "Figurenbild"
		add_child(preview)
		preview.setup(_data_root, false)
		preview.resize(_preview_rect.size * 2.0)
		var err = preview.show_char(int(me.get("race", 1)), int(me.get("gender", 0)), int(me.get("class", 1)), me.get("appearance", {}))
		if err != "":
			warnings.append("Figurenbild: " + err)
		else:
			preview.set_equipment(equip_models.call(inventory["equip"]))
		_preview_rect.texture = preview.texture()
	preview.set_active(true)

func _on_preview_input(event: InputEvent) -> void:
	var mm = event as InputEventMouseMotion
	if mm != null and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) and preview != null:
		preview.pivot.rotate_y(mm.relative.x * 0.01)

func _on_slot_input(event: InputEvent, kind: String, idx: int) -> void:
	var mb = event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_RIGHT:
		return
	if kind == "bag" and inventory["bag"].has(idx) and items != null and items.info(inventory["bag"][idx][0])["equip"]:
		equip_requested.emit(idx)
	elif kind == "equip" and inventory["equip"].has(idx):
		unequip_requested.emit(idx, -1)
	hide_tooltip()

func _slot_drag(_at: Vector2, kind: String, idx: int):
	var id = int(inventory["bag"].get(idx, [0, 0])[0]) if kind == "bag" else int(inventory["equip"].get(idx, 0))
	if id == 0:
		return null
	var pv = TextureRect.new()
	pv.texture = items.icon(id) if items != null else null
	pv.size = Vector2(36, 36)
	pv.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pv.stretch_mode = TextureRect.STRETCH_SCALE
	pv.modulate.a = 0.8
	var c = _slot_control(kind, idx)
	if c != null:
		c.set_drag_preview(pv)
	hide_tooltip()
	return {"kind": kind, "idx": idx, "id": id}

func _slot_can_drop(_at: Vector2, data, kind: String, idx: int) -> bool:
	if not data is Dictionary or not data.has("kind"):
		return false
	if kind == "bag":
		return idx < inventory["size"] and not (data["kind"] == "bag" and data["idx"] == idx)
	return data["kind"] == "bag" and items != null and items.info(int(data["id"]))["equip"] \
		and (int(items.info(int(data["id"])).get("mask", 0)) & (1 << idx)) != 0

func _slot_drop(_at: Vector2, data, kind: String, idx: int) -> void:
	if kind == "bag":
		if data["kind"] == "bag":
			move_item_requested.emit(int(data["idx"]), idx)
		else:
			unequip_requested.emit(int(data["idx"]), idx)
	else:
		equip_requested.emit(int(data["idx"]))

# ====================================================
# FERTIGKEITEN (Win_BaseSkill, Win_NewSKill, Schnellleisten Win_QuickBar0 / 1)
# ====================================================
func _setup_skills() -> void:
	for kind in ["skill", "new", "bar0", "bar1"]:
		for i in {"skill": SKILL_SLOTS, "new": NEW_SLOTS}.get(kind, BAR_SLOTS):
			_prep_skill(skill_control(kind, i), kind, i)
	var d = dlg(SKILLS)
	if d != null:
		for i in SKILL_SLOTS:
			d.set_text("Txt_%02d" % (i + 1), "")

func _prep_skill(c: Control, kind: String, idx: int) -> void:
	if c == null:
		return
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	var icon = TextureRect.new()
	icon.name = "Symbol"
	icon.size = c.size
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(icon)
	c.mouse_entered.connect(_on_skill_hover.bind(kind, idx))
	c.mouse_exited.connect(hide_tooltip)
	c.set_drag_forwarding(_skill_drag.bind(kind, idx), _skill_can_drop.bind(kind, idx), _skill_drop.bind(kind, idx))
	if kind != "new":
		var cool = CoolOverlay.new()
		cool.name = "Cool"
		cool.hud = self
		cool.size = c.size
		c.add_child(cool)
	if kind.begins_with("bar"):
		c.gui_input.connect(_on_skill_input.bind(kind, idx))

# Platz-Control wie in den Dialogen: Cmd_01..15 (K), Img_Skill1..16 (neu), Leiste 0 Sc_00..09, Leiste 1 Sc_10..19
func skill_control(kind: String, idx: int) -> Control:
	if kind == "skill":
		return dlg(SKILLS).item("Cmd_%02d" % (idx + 1)) if dlg(SKILLS) != null else null
	if kind == "new":
		return dlg(NEW_SKILLS).item("Img_Skill%d" % (idx + 1)) if dlg(NEW_SKILLS) != null else null
	var bar = int(kind.substr(3))
	var d = dlg(BAR_DIALOGS[bar])
	return d.item("Sc_%02d" % (bar * BAR_SLOTS + idx)) if d != null else null

# Bekannte Fertigkeiten in der Reihenfolge des Fensters
func skill_list() -> Array:
	var ids = skill_state["skills"].keys()
	ids.sort()
	return ids

# Fertigkeit an einem Platz, 0 = leer
func skill_at(kind: String, idx: int) -> int:
	match kind:
		"skill":
			var l = skill_list()
			var i = _skill_page * SKILL_SLOTS + idx
			return l[i] if i < l.size() else 0
		"new":
			var i = _new_page * NEW_SLOTS + idx
			return skill_state["new"][i] if i < skill_state["new"].size() else 0
	return int(skill_state["shortcuts"].get(Vector2i(int(kind.substr(3)), idx), 0))

# Zustand vom Server (world_ready skills: {skills: [[ID, Stufe]], new: [IDs], shortcuts: [[Leiste, Platz, ID]]})
func set_skills(state: Dictionary) -> void:
	var known = {}
	for e in state.get("skills", []):
		known[int(e[0])] = int(e[1])
	var sc = {}
	for e in state.get("shortcuts", []):
		sc[Vector2i(int(e[0]), int(e[1]))] = int(e[2])
	skill_state = {"skills": known, "new": state.get("new", []).map(func(x): return int(x)), "shortcuts": sc}
	refresh_skills()
	refresh_bars()
	refresh_new_skills()

func add_skill(id: int, level: int, is_new: bool) -> void:
	skill_state["skills"][id] = level
	if is_new and not id in skill_state["new"]:
		skill_state["new"].append(id)
	refresh_skills()
	refresh_bars()
	refresh_new_skills()

func set_shortcut(bar: int, slot: int, id: int) -> void:
	if id == 0:
		skill_state["shortcuts"].erase(Vector2i(bar, slot))
	else:
		skill_state["shortcuts"][Vector2i(bar, slot)] = id
	refresh_bars()

func skills_seen(ids: Array) -> void:
	for id in ids:
		skill_state["new"].erase(int(id))
	refresh_new_skills()

func refresh_skills() -> void:
	var d = dlg(SKILLS)
	if d == null:
		return
	var l = skill_list()
	var pages = maxi(1, ceili(l.size() / float(SKILL_SLOTS)))
	_skill_page = clampi(_skill_page, 0, pages - 1)
	for i in SKILL_SLOTS:
		var id = skill_at("skill", i)
		_set_skill_icon(skill_control("skill", i), id)
		d.set_text("Txt_%02d" % (i + 1), "%s\n%s" % [skills.skill_name(id), texts()["skill_level"] % skill_state["skills"][id]]
			if id != 0 and skills != null else "")
	d.set_text("Txt_Page", "%d/%d" % [_skill_page + 1, pages])
	d.show_item("Btn_Back", _skill_page > 0)
	d.show_item("Btn_Next", _skill_page < pages - 1)
	d.show_item("Lab_Back", _skill_page > 0)
	d.show_item("Lab_Next", _skill_page < pages - 1)

func refresh_bars() -> void:
	for b in BAR_DIALOGS.size():
		for i in BAR_SLOTS:
			_set_skill_icon(skill_control("bar%d" % b, i), skill_at("bar%d" % b, i))

func refresh_new_skills() -> void:
	var d = dlg(NEW_SKILLS)
	if d == null:
		return
	var n = skill_state["new"].size()
	if n == 0:
		if d.visible:
			aui.hide_dialog(d)
			hide_tooltip()
		return
	_new_page = clampi(_new_page, 0, (n - 1) / NEW_SLOTS)
	for i in NEW_SLOTS:
		var id = skill_at("new", i)
		_set_skill_icon(skill_control("new", i), id)
		d.show_item("Img_Skill%d" % (i + 1), id != 0)
		d.show_item("Img_IconBack%d" % (i + 1), id != 0)
	d.show_item("Btn_PageDown", n > (_new_page + 1) * NEW_SLOTS)
	d.show_item("Btn_PageUp", _new_page > 0)
	if not d.visible:
		aui.show_dialog(d)

func new_skills_shown() -> bool:
	return window_open(NEW_SKILLS)

func _set_skill_icon(c: Control, id: int) -> void:
	if c == null or c.get_node_or_null("Symbol") == null:
		return
	(c.get_node("Symbol") as TextureRect).texture = skills.icon(id) if id != 0 and skills != null else null
	c.set_meta("skill", id)

# Linksklick (ohne Ziehen) auf einen Platz einer Schnellleiste: einsetzen
func _on_skill_input(event: InputEvent, kind: String, idx: int) -> void:
	var mb = event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and not get_viewport().gui_is_dragging():
		var id = skill_at(kind, idx)
		if id != 0:
			skill_use_requested.emit(id)

# Abklingzeit beginnt (Meldung cooldown)
func set_cooldown(id: int, ms: int) -> void:
	if ms > 0:
		cooldowns[id] = [Time.get_ticks_msec() + ms, ms]
	else:
		cooldowns.erase(id)

# Restliche Abklingzeit 0 - 1
func cool_fraction(id: int) -> float:
	var c = cooldowns.get(id)
	if c == null:
		return 0.0
	var left = int(c[0]) - Time.get_ticks_msec()
	if left <= 0:
		cooldowns.erase(id)
		return 0.0
	return clampf(float(left) / maxf(1.0, float(c[1])), 0.0, 1.0)

func mana_ok(id: int) -> bool:
	return int(stats.get("mp", 0)) >= int(skill_info.get(str(id), {}).get("mp", 0))

func _on_skill_hover(kind: String, idx: int) -> void:
	var id = skill_at(kind, idx)
	if id == 0 or skills == null:
		hide_tooltip()
		return
	var context = 1 if kind.begins_with("bar") else 0 # SkillDesc.CONTEXT: QUICK_BAR / SKILL_INTERFACE
	show_tooltip(skills.bbcode(skills.desc(id, int(skill_state["skills"].get(id, 1)), context)))

func _skill_drag(_at: Vector2, kind: String, idx: int):
	var id = skill_at(kind, idx)
	if id == 0:
		return null
	var pv = TextureRect.new()
	pv.texture = skills.icon(id) if skills != null else null
	pv.size = Vector2(36, 36)
	pv.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pv.stretch_mode = TextureRect.STRETCH_SCALE
	pv.modulate.a = 0.8
	var c = skill_control(kind, idx)
	if c != null:
		c.set_drag_preview(pv)
	hide_tooltip()
	_drag_shortcut = Vector2i(int(kind.substr(3)), idx) if kind.begins_with("bar") else Vector2i(-1, -1)
	return {"skill": id, "from": kind, "idx": idx}

func _skill_can_drop(_at: Vector2, data, kind: String, _idx: int) -> bool:
	return kind.begins_with("bar") and data is Dictionary and data.has("skill")

func _skill_drop(_at: Vector2, data, kind: String, idx: int) -> void:
	var bar = int(kind.substr(3))
	var id = int(data["skill"])
	var from = str(data["from"])
	_drag_shortcut = Vector2i(-1, -1)
	if from.begins_with("bar"):
		var src = Vector2i(int(from.substr(3)), int(data["idx"]))
		if src == Vector2i(bar, idx):
			return
		var other = int(skill_state["shortcuts"].get(Vector2i(bar, idx), 0))
		shortcut_requested.emit(bar, idx, id)
		shortcut_requested.emit(src.x, src.y, other) # tauschen bzw. leeren
		return
	shortcut_requested.emit(bar, idx, id)
	if from == "new":
		skills_seen([id])
		skills_seen_requested.emit([id])

# Aus einer Schnellleiste gezogen und nirgends abgelegt: Platz leeren
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drag_shortcut.x >= 0:
		var src = _drag_shortcut
		_drag_shortcut = Vector2i(-1, -1)
		if is_inside_tree() and not get_viewport().gui_is_drag_successful():
			shortcut_requested.emit(src.x, src.y, 0)

# Tooltip: Fenster am Mauszeiger mit der Beschreibung (item_data.gd tooltip)
func _setup_tooltip() -> void:
	_tooltip = PanelContainer.new()
	_tooltip.name = "Tooltip"
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.05, 0.9)
	sb.border_color = Color(0.55, 0.47, 0.3)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(6)
	_tooltip.add_theme_stylebox_override("panel", sb)
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_text = RichTextLabel.new()
	_tooltip_text.bbcode_enabled = true
	_tooltip_text.fit_content = true
	_tooltip_text.scroll_active = false
	_tooltip_text.custom_minimum_size = Vector2(230, 0)
	_tooltip_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tooltip_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_text.add_theme_font_size_override("normal_font_size", 12)
	_tooltip.add_child(_tooltip_text)
	_tooltip.visible = false
	_tooltip.z_index = 100
	aui.add_child(_tooltip)

func _on_slot_hover(kind: String, idx: int) -> void:
	var id = int(inventory["bag"].get(idx, [0, 0])[0]) if kind == "bag" else int(inventory["equip"].get(idx, 0))
	if id == 0 or items == null:
		hide_tooltip()
		return
	var count = int(inventory["bag"].get(idx, [0, 1])[1]) if kind == "bag" else 1
	show_tooltip(items.tooltip(id, count, me, texts(), class_name_of))

func show_tooltip(bbcode: String) -> void:
	_tooltip_text.text = bbcode
	_tooltip.reset_size()
	var at = aui.get_local_mouse_position() + Vector2(16, 16)
	var limit = aui.size - _tooltip.size
	_tooltip.position = Vector2(minf(at.x, limit.x), minf(at.y, limit.y)).max(Vector2.ZERO)
	_tooltip.visible = true

func hide_tooltip() -> void:
	if _tooltip != null:
		_tooltip.visible = false

func tooltip_text() -> String:
	return _tooltip_text.get_parsed_text() if _tooltip != null and _tooltip.visible else ""

# Fortschritt beim Sammeln (Win_Prgs): text, Anteil 0 - 1; text "" schließt
func set_progress(text: String, f: float) -> void:
	var d = dlg(PROGRESS)
	if d == null:
		return
	if text == "":
		aui.hide_dialog(d)
		return
	d.set_progress("Prgs", 100.0 * clampf(f, 0.0, 1.0))
	d.set_text("Txt_info", "%s  %d%%" % [text, roundi(100.0 * clampf(f, 0.0, 1.0))])
	if not d.visible:
		aui.show_dialog(d)

func progress_shown() -> bool:
	return window_open(PROGRESS)


# ====================================================
# MINIMAP (Win_MiniMap)
# ====================================================
# Regel der Tab-Auswahl (SelectTargetRule.lua, Zone 0): R = höchstens so weit, bis r in jede Richtung,
# darüber nur innerhalb angle Grad um die Blickrichtung der Kamera (CECHostPlayer::CanSelectByTab)
var tab_rule = {"r": 5.0, "R": 20.0, "angle": 120.0}

# Kartenbild und Name aus den Lua-Skripten der Sprache (InstanceWorld.lua / InstanceStr.lua)
func _read_map_data(data_root: String, world_id: int) -> void:
	var files = load(FILES).new(data_root)
	var script_dir = ""
	for base in [language + "/script", "resources/" + language + "/script"]:
		var p = files.resolve(base)
		if p != "":
			script_dir = p
			break
	if script_dir == "":
		warnings.append("Не найдены Lua-скрипты (%s/script)" % language)
		return
	var lua = load(LUA).new(files)
	var path = files.resolve("instanceworld.lua", script_dir)
	var err = lua.run_file(path) if path != "" else "Не найден InstanceWorld.lua"
	if err != "":
		warnings.append(err)
	var inst = lua.value("Instance")
	var w = inst.get(world_id) if inst is Dictionary else null
	if not w is Dictionary or str(w.get("path", "")).to_lower() != map_name.to_lower():
		# Welt-ID passt nicht: nach dem Map-Ordner suchen
		w = null
		if inst is Dictionary:
			for k in inst:
				if k is int and inst[k] is Dictionary and str(inst[k].get("path", "")).to_lower() == map_name.to_lower():
					w = inst[k]
					world_id = k
					break
	map_title = str(lua.value("Instance.Str.name_%d" % world_id)) if lua.value("Instance.Str.name_%d" % world_id) != null else map_name
	if w is Dictionary:
		var zone = w.get(0)
		if not zone is Dictionary:
			for k in w:
				if k is int and w[k] is Dictionary and w[k].has("MiniMap"):
					zone = w[k]
					break
		if zone is Dictionary:
			var r = zone.get("rectMap", {})
			if r is Dictionary and r.size() >= 4:
				_map_rect = Rect2(float(r[1]), float(r[2]), float(r[3]) - float(r[1]), float(r[4]) - float(r[2]))
			_mark_tex["map"] = aui.texture(str(zone.get("MiniMap", "")))
	lua.close()
	var rule_lua = load(LUA).new(files)
	var rule_path = files.resolve("selecttargetrule.lua", script_dir)
	if rule_path != "" and rule_lua.run_file(rule_path) == "":
		var rule = rule_lua.value("SelectTargetRule.0")
		if rule is Dictionary:
			for k in tab_rule:
				if rule.has(k):
					tab_rule[k] = float(rule[k])
	rule_lua.close()

func _setup_minimap() -> void:
	var d = dlg("MiniMap")
	if d == null:
		return
	d.set_text("Btn_Bar", map_title)
	var bar = d.item("Btn_Bar")
	if bar is Button:
		bar.clip_text = false
	var area = d.item("Hide_2")
	if area == null:
		return
	_radar = ColorRect.new()
	_radar.name = "Radar"
	_radar.size = area.size
	_radar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat = ShaderMaterial.new()
	var sh = Shader.new()
	sh.code = RADAR_SHADER
	mat.shader = sh
	var map_tex = _mark_tex.get("map")
	mat.set_shader_parameter("map_tex", map_tex)
	mat.set_shader_parameter("has_map", map_tex != null and _map_rect.size.x != 0.0)
	mat.set_shader_parameter("mask_tex", aui.texture("InGame\\MiniMapMask.tga"))
	var half = RADAR_DIAMETER * MAP_ZOOM * 0.5
	if _map_rect.size.x != 0.0:
		mat.set_shader_parameter("half_size", Vector2(-half / absf(_map_rect.size.x), half / absf(_map_rect.size.y))) # gespiegelt
	_radar.material = mat
	area.add_child(_radar)
	_radar_marks = RadarMarks.new()
	_radar_marks.size = area.size
	_radar_marks.mouse_filter = Control.MOUSE_FILTER_STOP
	_radar_marks.gui_input.connect(_on_radar_input)
	area.add_child(_radar_marks)
	for k in MARKS:
		_mark_tex[k] = aui.texture(MARKS[k])
	_arrow = TextureRect.new()
	_arrow.texture = aui.texture("InGame\\MiniMapDir.tga")
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _arrow.texture != null:
		_arrow.size = _arrow.texture.get_size()
		_arrow.pivot_offset = _arrow.size / 2.0
		_arrow.position = (area.size - _arrow.size) / 2.0
	area.add_child(_arrow)

# Ziel der Autoroute (Vector3) oder null
func set_route_target(pos) -> void:
	route_target = pos

# Linksklick auf die Minimap -> Weltpunkt (gespiegelt wie die Anzeige)
func _on_radar_input(event: InputEvent) -> void:
	var mb = event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var off = mb.position - _radar_marks.size / 2.0
	if off.length() <= _radar_marks.size.x / 2.0:
		map_route_requested.emit(radar_to_world(off))

# Abstand zur Mitte der Minimap (Pixel) -> Weltpunkt (x, z)
func radar_to_world(off: Vector2) -> Vector2:
	return Vector2(_radar_pos.x - off.x / _radar_scale, _radar_pos.z - off.y / _radar_scale)

# Jedes Bild: eigene Position / Richtung und die Figuren in der Nähe ([Vector3, Art], Art wie MARKS)
func update_minimap(pos: Vector3, dir: float, others: Array) -> void:
	if _radar == null:
		return
	if route_target != null:
		others = others + [[route_target, "route"]]
	if _map_rect.size.x != 0.0:
		var uv = Vector2((pos.x - _map_rect.position.x) / _map_rect.size.x, (pos.z - _map_rect.position.y) / _map_rect.size.y)
		_radar.material.set_shader_parameter("center", uv)
	_arrow.rotation = -dir # Blick +Z = nach oben, +X (in Godot links) = nach links
	var radius = _radar.size.x / 2.0
	var scale_px = radius / (RADAR_DIAMETER * MAP_ZOOM * 0.5)
	_radar_pos = pos
	_radar_scale = scale_px
	var marks = []
	for o in others:
		var p: Vector3 = o[0]
		var off = Vector2(-(p.x - pos.x), -(p.z - pos.z)) * scale_px
		if o[1] == "route" and off.length() >= radius - 8.0:
			off = off.limit_length(radius - 8.0) # Ziel außerhalb: am Rand in seiner Richtung
		if off.length() < radius - 3.0:
			marks.append([_radar.size / 2.0 + off, _mark_tex.get(o[1])])
	_radar_marks.marks = marks
	_radar_marks.queue_redraw()
