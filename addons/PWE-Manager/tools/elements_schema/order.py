import os
BASE=os.path.dirname(os.path.abspath(__file__))+'/'
import re, json, struct, sys
cpp=open(BASE+'edm.cpp').read(); h=open(BASE+'edm.h').read()
load=cpp[cpp.index('int elementdataman::load_data'):]
load=load[:load.index('size32_t sz = 0;')]
order=re.findall(r'(\w+_array)\.load\(file\)',load)
decl=dict((n,t) for t,n in re.findall(r'array<\s*(\w+)\s*>\s*(\w+_array)\s*;',h))
types=[decl[n] for n in order]
schema=json.load(open(BASE+'schema.json'))
def walk(path):
    b=open(path,'rb').read(); p=4+132; lists=[]
    while p+8<=len(b):
        a,c=struct.unpack_from('<II',b,p)
        if a==0x19e75edf: ln=struct.unpack_from('<I',b,p+4)[0]; p+=8+ln+4; continue
        if a==0xee35679f: ln=struct.unpack_from('<I',b,p+4)[0]; p+=8+ln; continue
        if a==0 or a>200000 or c>2000000 or p+8+a*c>len(b): break
        lists.append((a,c,p+8)); p+=8+a*c
    return lists,b
cl,cb=walk(os.environ.get('CLIENT_ELEMENTS','client_elements.data'))
sv,sb=walk(os.environ.get('SERVER_ELEMENTS','server_elements.data'))
json.dump({'order':types},open(BASE+'order.json','w'))
if __name__=='__main__':
    print('v260 Listen:', len(types), 'Client', len(cl), 'Server253', len(sv))
    same=0
    for i in range(max(len(types),len(cl))):
        t=types[i] if i<len(types) else '?'
        s=schema[t]['size'] if t in schema else None
        c=cl[i][:2] if i<len(cl) else None; v=sv[i][:2] if i<len(sv) else None
        if c and s==c[0]: same+=1
        if c is None or s!=c[0] or t in ('MONSTER_ESSENCE','NPC_ESSENCE','MINE_ESSENCE'):
            print(f'{i:3} {t:42} v260={s} client={c} server253={v}')
    print('gleich groß:', same)
