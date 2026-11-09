# Startwerte je Rasse / Klasse / Geschlecht aus gamedbd/clsconfig (FW_496) -> Server/start_roles.json
# Aufruf: RPCALLS=<v260_server>/wnet_20131107/rpcalls.xml python3 clsconfig.py <clsconfig> <gs.conf> <maps.json> <Ausgabe>
# clsconfig: Tabelle im wnet-Format (gdb.py), Werte GNET-Marshal (gmarshal.py). GRoleBase dieser
# Server-Version weicht vom Quellcode ab; GRoleStatus wird über sein Muster (Version 1 + Rollen-ID)
# gefunden und ist danach vollständig lesbar, dann Inventar und Lager.
import sys, os, re, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdb import records
from gmarshal import R

RACES = {1: 'Mensch', 2: 'Elf', 3: 'Zwerg', 4: 'Steinmensch', 5: 'Kindred', 6: 'Wolf'}
CLASSES = {1: 'Krieger', 2: 'Patriot', 3: 'Assassine', 4: 'Schütze', 5: 'Magier', 6: 'Priester', 7: 'Vampir', 8: 'Barde'}

cls, gsconf, mapsjson, out = sys.argv[1:5]
conf = open(gsconf, 'rb').read().decode('gbk', 'replace')
tag_folder = {}
for name, body in re.findall(r'\[(Map_[^\]]+)\]([^\[]*)', conf):
    d = dict((k, v.strip()) for k, v in re.findall(r'^\s*(\w+)\s*=\s*([^\n#;]*)', body, re.M))
    if d.get('tag') and d.get('base_path'):
        tag_folder[int(d['tag'])] = d['base_path'].strip().rstrip('/')
folder_map = {}
for cm, srcs in json.load(open(mapsjson))['maps'].items():
    for s in srcs:
        folder_map.setdefault(s['folder'], cm)
roles = []
for k, v in sorted(records(cls)):
    rid = int.from_bytes(k, 'big')
    pat = bytes([1]) + k
    h = [i for i in range(10, len(v)) if v[i:i + 9] == pat][0]
    r = R(v)
    r.p = h
    st = r.read('GRoleStatus')
    pk = r.read('GRolePocket')
    r.read('GRoleStorehouse')
    folder = tag_folder.get(st['worldtag'], '')
    roles.append({
        'role_id': rid, 'race': st['race'], 'race_name': RACES.get(st['race'], ''),
        'class': st['occupation'], 'class_name': CLASSES.get(st['occupation'], ''),
        'gender': v[16], 'level': st['level'], 'hp': st['hp'], 'mp': st['mp'],
        'world': st['worldtag'], 'server_folder': folder, 'map': folder_map.get(folder, ''),
        'pos': [round(st['posx'], 3), round(st['posy'], 3), round(st['posz'], 3)],
        'town_world': st['towntag'], 'town_pos': [st['townx'], st['towny'], st['townz']],
        'inventory_size': pk['capacity'], 'money': pk['money'],
        'items': [{'id': i['id'], 'pos': i['pos'], 'count': i['count']} for i in pk['items']],
        'equipment': [{'id': i['id'], 'pos': i['pos']} for i in pk['equipment']],
        'skills_raw': st['skills'].hex()})
json.dump({'source': 'FW_496 server-fw/gamedbd/clsconfig (GRoleStatus, GRolePocket); gender 0 = maennlich, 1 = weiblich',
           'roles': roles}, open(out, 'w'), ensure_ascii=False, indent=1)
print(len(roles), 'Startvorlagen ->', out)
