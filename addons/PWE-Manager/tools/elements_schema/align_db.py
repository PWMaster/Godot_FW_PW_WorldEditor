import os
import sqlite3, struct, re, sys
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from align import *
db=sqlite3.connect(os.environ.get('ELEMENTS_DB','ElementsV1.db'))
cols=[r[1] for r in db.execute('pragma table_info(Elements_EQUIPMENT_ESSENCE)')]
rows={r[0]:dict(zip(cols,r)) for r in db.execute('select * from Elements_EQUIPMENT_ESSENCE')}
idx=1; t=types[idx]; C=recs(cl,cb,idx)
ids=[i for i in rows if i in C][:400]
print('gemeinsame IDs', len(ids), 'von', len(rows))
def dbname(leaf):
    # models[0].profession -> models_profession1 ; refine_price[3] -> refine_price4 ; color[0] -> color1
    m=re.match(r'(\w+)\[(\d+)\]\.(\w+)$',leaf)
    if m: return f'{m[1]}_{m[3]}{int(m[2])+1}'
    m=re.match(r'(\w+)\[(\d+)\]$',leaf)
    if m: return f'{m[1]}{int(m[2])+1}'
    m=re.match(r'(\w+)\[(\d+)\]\.(\w+)\[(\d+)\]$',leaf)
    return leaf
L=leaves(t); lc=cl[idx][0]; delta=lc-schema[t]['size']
res=[]
for name,ft,off,sz in L:
    col=dbname(name)
    if col not in cols or ft=='wchar': continue
    best=None
    for k in range(-16, delta+17, 4):
        o=off+k
        if o<0 or o+sz>lc: continue
        hit=0; n=0
        for i in ids:
            v=rows[i][col]
            if v is None or v=='': continue
            try: v=float(v)
            except: continue
            raw=C[i][o:o+sz]
            x=struct.unpack('<f',raw)[0] if ft=='f32' else int.from_bytes(raw,'little',signed=ft.startswith('i'))
            n+=1; hit+= abs(x-v)<1e-3
        if n and (best is None or hit/n>best[1]): best=(k,hit/n,n)
    if best: res.append((off,name,col,best))
for off,name,col,b in res:
    print(f'{off:4} {name:40} {col:36} Verschiebung {b[0]:4}  Treffer {b[1]:.2f} ({b[2]})')

# DP wie align(): Verschiebung nicht fallend, nur Felder mit aussagekräftigen Werten (nicht alle gleich)
ks=list(range(0,delta+1,4))
sc=[]
for name,ft,off,sz in L:
    col=dbname(name)
    row=[0.0]*len(ks)
    if col in cols and ft!='wchar':
        vals=[rows[i][col] for i in ids]
        try: vals=[float(v) for v in vals]
        except: vals=None
        if vals and len(set(vals))>1:
            for j,k in enumerate(ks):
                o=off+k
                if o+sz>lc: row[j]=-1; continue
                hit=0
                for i,v in zip(ids,vals):
                    raw=C[i][o:o+sz]
                    x=struct.unpack('<f',raw)[0] if ft=='f32' else int.from_bytes(raw,'little',signed=ft.startswith('i'))
                    hit+=abs(x-v)<1e-3
                row[j]=hit/len(ids)-0.5
    sc.append(row)
n=len(L); best=[[-1e9]*len(ks) for _ in range(n)]; back=[[0]*len(ks) for _ in range(n)]
for j in range(len(ks)): best[0][j]=sc[0][j]
for i in range(1,n):
    run=-1e9; arg=0
    for j in range(len(ks)):
        if best[i-1][j]>run: run=best[i-1][j]; arg=j
        best[i][j]=run+sc[i][j]-0.0001*j; back[i][j]=arg
j=max(range(len(ks)),key=lambda j:best[n-1][j]); path=[0]*n
for i in range(n-1,-1,-1):
    path[i]=ks[j]; j=back[i][j] if i>0 else j
prev=0; steps=[]
for i,(name,ft,off,sz) in enumerate(L):
    if path[i]!=prev: steps.append([off,path[i],name]); prev=path[i]
print('EQUIPMENT Schritte:', steps)
bad=[(L[i][0],round(sc[i][ks.index(path[i])]+0.5,2)) for i in range(n) if sc[i][ks.index(path[i])]<0.4 and sc[i][ks.index(path[i])]!=0.0]
print('schwach:', bad[:10])
json.dump(steps,open(BASE+'equipment_steps.json','w'))
