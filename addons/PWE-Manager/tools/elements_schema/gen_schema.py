# Erzeugt aus exptypes.h (pack 4) Feldbeschreibungen und die Listen-Reihenfolge aus elementdataman.cpp/.h
import re, sys, json
src=open(sys.argv[1],encoding='utf-8').read()
src=re.sub(r'/\*.*?\*/','',src,flags=re.S); src=re.sub(r'//[^\n]*','',src)
defines={}
for k,v in re.findall(r'#define\s+(\w+)\s+([^\n]+)',src):
    defines[k]=v.strip()
PRIM={'int':('i32',4),'unsigned int':('u32',4),'unsigned':('u32',4),'float':('f32',4),'double':('f64',8),
 'short':('i16',2),'unsigned short':('u16',2),'char':('i8',1),'unsigned char':('u8',1),'bool':('bool',1),
 'namechar':('wchar',2),'long long':('i64',8),'unsigned long long':('u64',8),'int64_ed':('i64',8),'uint64_ed':('u64',8),
 'size32_t':('u32',4),'time32_t':('i32',4),'DWORD':('u32',4),'BYTE':('u8',1),'WORD':('u16',2),'long':('i32',4),'unsigned long':('u32',4)}
enums=set(re.findall(r'enum\s+(\w+)',src))
def ev(e):
    e=e.strip()
    for k in sorted(defines,key=len,reverse=True):
        if re.fullmatch(r'-?[0-9xXa-fA-F]+',defines[k].strip()) or re.fullmatch(r'[0-9 +*()-/]+',defines[k]):
            e=re.sub(r'\b%s\b'%k,defines[k],e)
    return int(eval(e,{},{}))
structs={}
def parse_body(body, prefix_name):
    # -> Liste von Feldern (name, typ, dims) ; verschachtelte anonyme structs als eigene Typen
    fields=[]; i=0; toks=body
    pos=0
    while True:
        m=re.compile(r'\s*').match(toks,pos); pos=m.end()
        if pos>=len(toks): break
        if toks.startswith('struct',pos) and re.match(r'struct\s*(\w*)\s*\{',toks[pos:]):
            mm=re.match(r'struct\s*(\w*)\s*\{',toks[pos:]); start=pos+mm.end(); depth=1; j=start
            while depth:
                if toks[j]=='{': depth+=1
                elif toks[j]=='}': depth-=1
                j+=1
            inner=toks[start:j-1]
            m2=re.match(r"\s*(\w+)((?:\s*\[[^\]]+\])*)\s*;",toks[j:])
            if m2 is None: raise Exception("verschachtelt in %s: %r" % (prefix_name, toks[j:j+80]))
            name=m2.group(1); dims=[ev(d) for d in re.findall(r'\[([^\]]+)\]',m2.group(2))]
            tname=(mm.group(1) or prefix_name+'__'+name)
            structs[tname]=parse_body(inner,tname)
            fields.append((name,tname,dims)); pos=j+m2.end(); continue
        end=toks.find(';',pos)
        decl=toks[pos:end].strip(); pos=end+1
        if not decl or decl.startswith('#') : continue
        decl=re.sub(r'\s+',' ',decl)
        m=re.match(r'((?:const |unsigned |signed )*(?:long long|\w+)(?: int)?)\s+(.+)$',decl)
        if not m: raise Exception('Deklaration? %r in %s'%(decl,prefix_name))
        t=m.group(1).strip(); rest=m.group(2)
        if t.startswith('struct '): t=t[7:]
        for d in rest.split(','):
            d=d.strip(); mm=re.match(r'(\w+)((?:\s*\[[^\]]+\])*)',d)
            fields.append((mm.group(1),t,[ev(x) for x in re.findall(r'\[([^\]]+)\]',mm.group(2))]))
    return fields
for m in re.finditer(r'\nstruct\s+(\w+)\s*\{',src):
    name=m.group(1); start=m.end(); depth=1; j=start
    if name=='talk_proc': continue  # Gesprächsdaten mit eigener load-Funktion
    while depth:
        if src[j]=='{': depth+=1
        elif src[j]=='}': depth-=1
        j+=1
    body=src[start:j-1]
    body=re.sub(r'\b\w+\s*\([^)]*\)\s*(const)?\s*\{[^{}]*\}','',body)  # Methoden entfernen
    body=re.sub(r'\b\w+\s*\([^)]*\)\s*;','',body)
    structs[name]=parse_body(body,name)
layout={}
def lay(t):
    if t in PRIM: return PRIM[t][1],min(PRIM[t][1],4)
    if t in enums: return 4,4
    if t in layout: return layout[t]['size'],layout[t]['align']
    fs=structs[t]; off=0; al=1; out=[]
    for name,ft,dims in fs:
        sz,a=lay(ft); n=1
        for d in dims: n*=d
        off=(off+a-1)//a*a
        out.append([name, PRIM[ft][0] if ft in PRIM else ('u32' if ft in enums else ft), off, dims])
        off+=sz*n; al=max(al,a)
    size=(off+al-1)//al*al
    layout[t]={'size':size,'align':al,'fields':out}
    return size,al
for t in list(structs): lay(t)
json.dump(layout,open(sys.argv[2],'w'),ensure_ascii=False)
print(len(layout),'Strukturen; MONSTER_ESSENCE',layout['MONSTER_ESSENCE']['size'],'NPC_ESSENCE',layout['NPC_ESSENCE']['size'],'EQUIPMENT_ESSENCE',layout['EQUIPMENT_ESSENCE']['size'],'EQUIPMENT_ADDON',layout['EQUIPMENT_ADDON']['size'],'ExportInfo',layout['ElementDataExportInfo']['size'])
