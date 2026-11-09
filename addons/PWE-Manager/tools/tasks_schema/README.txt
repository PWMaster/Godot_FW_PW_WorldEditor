Erzeugt angelica_tasks_schema.json (Beschreibung für angelica_tasks.gd).

Eingaben (in diesen Ordner, UTF-8):
  T=<27_2014_07_04_v260>/.../SMElement/SMElementClient/Task
  iconv -f GBK -t UTF-8 $T/TaskTempl.h > TaskTempl.h
  for f in $T/*.h; do iconv -f GBK -t UTF-8 -c "$f"; done > task_all_h.txt   (Konstanten)

Ablauf:
  python3 gen_tasks_schema.py ../../Data/angelica_tasks_schema.json
  (Eingaben woanders: TASKTEMPL_H=<Datei> TASK_HEADERS=<Datei> davorsetzen)
Geprüft 2026-11-02: Ausgabe byte-gleich mit der mitgelieferten angelica_tasks_schema.json.

Strukturen: Quellcode v181, pack 1; vor jedem Zeiger steht unter WIN32 ein 4-Byte-Füllfeld,
ein Zeiger belegt also 8 Bytes (Füllfeld + 4-Byte-Zeiger).

Einfügestellen der Client-Version 184 (in gen_tasks_schema.py eingetragen), so ermittelt:
  - Kleinste Quest 9.327 statt 9.295 Bytes: 32 Bytes mehr in festem Teil + 2 Belohnungen.
  - Für das Lesen zählen nur die Zähler-Felder (m_ulPremItems, m_ulMonsterWanted ...): alle
    Verteilungen der Verschiebung über die Zähler und Größen probiert, Kriterium "jede Quest
    endet genau am nächsten Offset der Teildatei" -> fester Teil +4 nach m_ulTimetable und
    +4 nach m_ulTeamMemsWanted, AWARD_DATA +12: alle 11.572 Quests gehen auf.
  - Genaue Lage in den Bereichen über plausible Werte: +4 vor m_ulPremise_Lev_Max (NPC-IDs
    und Stufen zu 99,998 % plausibel), m_enumMethod bei 3554 + 8 (Art 1 / 2 genau dann, wenn
    Monster- / Gegenstandsliste gefüllt).
Eine neue Version: Quests nach demselben Verfahren prüfen und ihre Werte unter "versions" eintragen.
