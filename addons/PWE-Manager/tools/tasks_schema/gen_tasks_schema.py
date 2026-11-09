# Erzeugt angelica_tasks_schema.json: Quest-Strukturen (TaskTempl.h v181, pack 1, WIN32-Zeiger) und
# die Einfügestellen je Datei-Version (ermittelt aus dem exakten Aufgehen aller Quests, siehe README.txt)
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from task_layout import layout, LAY

NAMES = ['ATaskTemplFixedData', 'AWARD_DATA', 'ITEM_WANTED', 'MONSTER_WANTED', 'TEAM_MEM_WANTED', 'task_tm']
for n in NAMES:
    layout(n)
structs = {}
for name, L in LAY.items():
    structs[name] = {'size': L['size'], 'fields': [[f[0], f[1], f[2], f[3], f[4]] for f in L['fields']]}
out = {'source': 'TaskTempl.h / TaskTempl.cpp (v181, pack 1, Zeiger mit WIN32-Fuellfeld = 8 Bytes)',
       'base_version': 181,
       'versions': {
           '181': {'fixed_size': structs['ATaskTemplFixedData']['size'], 'fixed_steps': [],
                   'award_size': structs['AWARD_DATA']['size'], 'award_steps': []},
           '184': {'fixed_size': structs['ATaskTemplFixedData']['size'] + 8, 'fixed_steps': [[447, 4], [3554, 8]],
                   'award_size': structs['AWARD_DATA']['size'] + 12, 'award_steps': [],
                   'note': '+4 zwischen m_ulPremise_Lev_Min und _Max, +4 vor m_enumMethod (Lage im Bereich 2638-3554 '
                           'nicht genauer bekannt), AWARD_DATA +12 am Ende'}},
       'structs': structs}
json.dump(out, open(sys.argv[1], 'w'), ensure_ascii=False, separators=(',', ':'))
print('Strukturen', len(structs), 'fest', structs['ATaskTemplFixedData']['size'], 'Belohnung', structs['AWARD_DATA']['size'])
