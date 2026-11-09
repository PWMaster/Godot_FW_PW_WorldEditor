# Zerlegt GNET-Marshal-Daten anhand der rpcdata-Beschreibungen in rpcalls.xml
import re, struct, html
import os
RPC=os.environ.get('RPCALLS','rpcalls.xml')  # wnet_*/rpcalls.xml des Server-Quellcodes
txt=open(RPC,'rb').read().decode('gbk','replace')
txt=re.sub(r'<!--.*?-->','',txt,flags=re.S)
TYPES={}
for name,attrs,body in re.findall(r'<rpcdata name="(\w+)"([^>]*)>(.*?)</rpcdata>',txt,re.S):
    fields=[(m[0],html.unescape(m[1])) for m in re.findall(r'<variable name="(\w+)" type="([^"]+)"',body)]
    TYPES[name]=(fields,'vector' in attrs)
PRIM={'char':('>b',1),'unsigned char':('>B',1),'byte':('>B',1),'bool':('>B',1),'short':('>h',2),'unsigned short':('>H',2),
 'int':('>i',4),'unsigned int':('>I',4),'int64_t':('>q',8),'float':('>f',4),'double':('>d',8),'long':('>i',4)}
class R:
    def __init__(s,b): s.b=b; s.p=0
    def cu(s):
        c=s.b[s.p]
        if c&0xe0==0xe0: v=struct.unpack_from('>I',s.b,s.p+1)[0]; s.p+=5
        elif c&0xe0==0xc0: v=struct.unpack_from('>I',s.b,s.p)[0]&~0xc0000000; s.p+=4
        elif c&0xc0==0x80: v=struct.unpack_from('>H',s.b,s.p)[0]&~0x8000; s.p+=2
        else: v=c; s.p+=1
        return v
    def read(s,t):
        if t in PRIM:
            f,n=PRIM[t]; v=struct.unpack_from(f,s.b,s.p)[0]; s.p+=n; return v
        if t=='Octets':
            n=s.cu(); v=s.b[s.p:s.p+n]; s.p+=n; return v
        m=re.match(r'std::vector<\s*(.+?)\s*>$',t)
        if m: return [s.read(m[1]) for _ in range(s.cu())]
        if t.endswith('Vector') and t[:-6] in TYPES: return [s.read(t[:-6]) for _ in range(s.cu())]
        if t in TYPES:
            out={}
            for fn,ft in TYPES[t][0]: out[fn]=s.read(ft)
            return out
        raise Exception('Typ? '+t)
