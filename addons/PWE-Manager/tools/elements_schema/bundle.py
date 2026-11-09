import os
# Bündelt Strukturen (v260), Listen-Reihenfolge, ID-Räume und die Verschiebungen für v297 in eine JSON-Datei
import json, re, sys
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from align import *
cpp=open(BASE+'edm.cpp').read()
hm=cpp[cpp.index('void elementdataman::setup_hash_map'):]
space=dict((arr,sp) for sp,dt,arr in re.findall(r'ADD_HASH_MAP\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)',hm))
load=cpp[cpp.index('int elementdataman::load_data'):]; load=load[:load.index('size32_t sz = 0;')]
arrays=re.findall(r'(\w+_array)\.load\(file\)',load)
lists=[{'type':types[i],'space':space.get(a,'')} for i,a in enumerate(arrays)]
patch={}; unsafe=[]
for i in range(len(types)):
    t=types[i]
    if cl[i][0]==schema[t]['size']: continue
    if t=='EQUIPMENT_ESSENCE':
        steps=json.load(open(BASE+'equipment_steps.json'))
    else:
        r,e=align(i)
        if r is None: unsafe.append(t); continue
        steps=r['steps']
    patch[t]={'size':cl[i][0],'steps':[[s[0],s[1]] for s in steps]}
structs={k:{'size':v['size'],'fields':v['fields']} for k,v in layout_items} if False else {k:{'size':v['size'],'fields':v['fields']} for k,v in schema.items()}
out={'source':'exptypes.h / elementdataman.cpp (v260); Verschiebungen fuer v297 aus dem Vergleich Server-elements.data (v253) <-> Client (v297), Ausruestung mit ElementsV1.db',
     'base_version':0x10000260,'lists':lists,'tags':[{'after':33,'id':0x19e75edf,'time':True},{'after':67,'id':0xee35679f,'time':False}],
     'versions':{str(0x10000297):{'patch':patch,'unsafe':unsafe,'lists':206},str(0x10000253):{'patch':{},'unsafe':['EQUIPMENT_ESSENCE','SPECIAL_ID_CONFIG','CHAR_ATTRIB_EVAL_CONFIG'],'lists':193}},
     'structs':structs}
json.dump(out,open(sys.argv[1],'w'),ensure_ascii=False,separators=(',',':'))
print('Listen', len(lists), '(Listenzahl je Version: lists; danach beginnen die Gespräche)', 'Raeume', sorted(set(l['space'] for l in lists)), 'Patches v297', len(patch), 'unsicher', unsafe)
