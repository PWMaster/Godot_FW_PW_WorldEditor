# Ermittelt, wo v297-Strukturen gegenüber v260 Felder eingefügt haben (gleiche IDs in Server- und Client-Datei)
import json, struct, sys
from order import *
PS={'i32':4,'u32':4,'f32':4,'f64':8,'i16':2,'u16':2,'i8':1,'u8':1,'bool':1,'wchar':2,'i64':8,'u64':8}
def leaves(t, base=0, out=None, path=''):
    if out is None: out=[]
    for name,ft,off,dims in schema[t]['fields']:
        n=1
        for d in dims: n*=d
        if ft in PS:
            if ft=='wchar' and dims: out.append((path+name,'wchar',base+off,PS[ft]*n)); continue
            for k in range(n): out.append((path+name+(f'[{k}]' if n>1 else ''),ft,base+off+k*PS[ft],PS[ft]))
        else:
            sz=schema[ft]['size']
            for k in range(n): leaves(ft, base+off+k*sz, out, path+name+(f'[{k}]' if n>1 else '')+'.')
    return out
def recs(lst,b,idx):
    a,c,p=lst[idx]; return {struct.unpack_from('<I',b,p+i*a)[0]: b[p+i*a:p+(i+1)*a] for i in range(c)}
def align(idx):
    t=types[idx]; ls=sv[idx][0]; lc=cl[idx][0]
    if schema[t]['size']!=ls: return None,'v253-Größe passt nicht zu v260'
    S=recs(sv,sb,idx); C=recs(cl,cb,idx)
    ids=[i for i in S if i in C][:400]
    if len(ids)<5: return None,'zu wenige gemeinsame IDs'
    delta=lc-ls; ks=list(range(0,delta+1,4 if delta%4==0 else 1))
    if delta<0: return None,"v297 kleiner als v260"
    L=leaves(t)
    # Score je Blatt und Verschiebung
    sc=[]
    for name,ft,off,sz in L:
        row=[]
        for k in ks:
            if off+k+sz>lc: row.append(-1); continue
            row.append(sum(1 for i in ids if S[i][off:off+sz]==C[i][off+k:off+k+sz])/len(ids))
        sc.append(row)
    # DP: Verschiebung nicht fallend
    import math
    n=len(L); best=[[-1e9]*len(ks) for _ in range(n)]; back=[[0]*len(ks) for _ in range(n)]
    for j in range(len(ks)): best[0][j]=sc[0][j]
    for i in range(1,n):
        run=-1e9; arg=0
        for j in range(len(ks)):
            if best[i-1][j]>run: run=best[i-1][j]; arg=j
            best[i][j]=run+sc[i][j]-(0.001*j); back[i][j]=arg
    j=max(range(len(ks)),key=lambda j:best[n-1][j]); path=[0]*n
    for i in range(n-1,-1,-1):
        path[i]=ks[j]; j=back[i][j] if i>0 else j
    steps=[]; prev=0; weak=[]
    for i,(name,ft,off,sz) in enumerate(L):
        if path[i]!=prev: steps.append([off,path[i],name]); prev=path[i]
        if sc[i][ks.index(path[i])]<0.9: weak.append((name,round(sc[i][ks.index(path[i])],2)))
    return {'steps':steps,'weak':weak[:8],'n':len(ids)},None
if __name__=='__main__':
    for idx in [i for i in range(len(types)) if cl[i][0]!=schema[types[i]]["size"]]:
        r,e=align(idx); print(types[idx], e or r)
