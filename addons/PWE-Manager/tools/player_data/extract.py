# Tabellen zum Aussehen der Spielfiguren aus dem Client-Quellcode v260 -> angelica_player_data.json
# (nur Pfade und Farbwerte, kein Code). Eingaben UTF-8 (siehe README.txt):
#   EC_PlayerUtil.cpp  _player_ecm, _head_skin, _hair_skin, _equipment_default_fashion_*_skin,
#                      l_hashDefaultSkin (Standardkleidung je Rasse / Klasse / Geschlecht)
#   EC_Player.cpp      _skin_color (Hautfarben je Rasse, auskommentierte Zeilen zählen nicht)
#   DlgCreateSelectStyle.cpp  s_RdoHairColor (54 Haarfarben), s_DefHairColor
# Aufruf: python3 extract.py <EC_PlayerUtil.cpp> <EC_Player.cpp> <DlgCreateSelectStyle.cpp> <Ausgabe.json>
import re, sys, json

RACES = ['RACE_RESERVE', 'RACE_HUMAN', 'RACE_ELF', 'RACE_DWARF', 'RACE_GIANT', 'RACE_VAMPIRE', 'RACE_WEREWOLF']
PROFS = ['PROF_RESERVE', 'PROF_WARRIOR', 'PROF_GUARD', 'PROF_THIEF', 'PROF_GUNMAN', 'PROF_ENCHANTER', 'PROF_PRIEST',
         'PROF_BLOOD', 'PROF_POET', 'PROF_BLOODRAIDER']
GENDERS = ['GENDER_MALE', 'GENDER_FEMALE']
SLOTS = {'SKIN_INDEX_BODY': 'body', 'SKIN_INDEX_LEG': 'leg', 'SKIN_INDEX_FOOT': 'foot', 'SKIN_INDEX_WRIST': 'wrist'}


def uncomment(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return re.sub(r'//[^\n]*', '', s)


def body_of(src, name):
    m = re.search(r'\b%s\s*\[[^\]]*\](?:\s*\[[^\]]*\])?\s*=\s*\{' % re.escape(name), src)
    if not m:
        raise SystemExit('Tabelle fehlt: ' + name)
    i = m.end()
    depth = 1
    j = i
    while depth:
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
        j += 1
    return src[i:j - 1]


def path(p):
    return p.replace('\\\\', '/').replace('\\', '/')


def gender_table(src, name):
    # [Rasse][Geschlecht] Zeichenketten, Zeile 0 leer
    rows = re.findall(r'\{\s*"([^"]*)"\s*,\s*"([^"]*)"\s*\}', body_of(src, name))
    return {str(r): {'m': path(rows[r][0]), 'w': path(rows[r][1])} for r in range(1, len(rows))}


def main():
    util, player, style, out = sys.argv[1:5]
    u = uncomment(open(util, encoding='utf-8').read())
    p = uncomment(open(player, encoding='utf-8').read())
    s = uncomment(open(style, encoding='utf-8').read())
    data = {
        'source': 'Client v260: EC_PlayerUtil.cpp, EC_Player.cpp, DlgCreateSelectStyle.cpp (tools/player_data/extract.py)',
        'races': {str(i): RACES[i] for i in range(1, len(RACES))},
        'professions': {str(i): PROFS[i] for i in range(1, len(PROFS))},
        'ecm': gender_table(u, '_player_ecm'),
        'head': gender_table(u, '_head_skin'), # %02d-%02d: Gesicht + 1, Maske
        'hair': gender_table(u, '_hair_skin'), # %02d: Frisur + 1
        'fashion': {k: gender_table(u, '_equipment_default_fashion_%s_skin' % k) for k in ['hair', 'upper', 'lower', 'shoe']},
        'default_skins': {},
    }
    for race, prof, gender, slot, ski in re.findall(
            r'l_hashDefaultSkin\[_GetCompressKey\((\w+),\s*(\w+),\s*(\w+),\s*(\w+)\)\]\s*=\s*"([^"]+)"', u):
        key = '%d_%d_%s' % (RACES.index(race), PROFS.index(prof), 'm' if gender == 'GENDER_MALE' else 'w')
        data['default_skins'].setdefault(key, {})[SLOTS[slot]] = path(ski)
    colors = {}
    rows = re.findall(r'\{([^{}]*)\}', body_of(p, '_skin_color'))
    for r, row in enumerate(rows):
        if r == 0:
            continue
        colors[str(r)] = [[int(x) for x in c] for c in re.findall(r'A3DCOLORRGB\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)', row)]
    data['skin_colors'] = colors
    data['hair_colors'] = [[int(x) for x in c] for c in re.findall(r'\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}', body_of(s, 's_RdoHairColor'))]
    m = re.search(r's_DefHairColor\s*=\s*A3DCOLORRGB\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)', s)
    data['default_hair_color'] = [int(x) for x in m.groups()]
    json.dump(data, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print('Modelle %d, Standardkleidung %d, Hautfarben %s, Haarfarben %d' % (
        len(data['ecm']), len(data['default_skins']), {k: len(v) for k, v in colors.items()}, len(data['hair_colors'])))


main()
