# Liest Tabellen des wnet-Formats (common/db.h, PageBrowser) -> [(key, val)]
import struct
PAGESIZE=4096; PAGEUSED=PAGESIZE-8; HDR=12; END=PAGEUSED-HDR+HDR  # PAGEMAXSPARE+sizeof(data_hdr)
def hdr(b,page,pos):
    o=page*PAGESIZE+pos
    ni,np,first,nxt,size=struct.unpack_from('<IHHHH',b,o)
    return dict(ni=ni,np=np,first=first,next=nxt,size=size,o=o)
def is_data_page(b,page):
    pos=0
    for i in range(PAGEUSED//16):
        h=hdr(b,page,pos)
        if h['next']==END: return True
        if h['next']>PAGEUSED or h['next']<0: return False
        pos=h['next']
    return False
def records(path):
    b=open(path,'rb').read(); n=len(b)//PAGESIZE; out=[]
    data_pages={p for p in range(1,n) if is_data_page(b,p)}
    for p in sorted(data_pages):
        pos=0
        while True:
            h=hdr(b,p,pos)
            if h['size'] and h['first']:
                total=struct.unpack_from('<I',b,h['o']+HDR)[0]; buf=bytearray(); cur=h
                while True:
                    buf+=b[cur['o']+HDR:cur['o']+HDR+cur['size']]
                    if not cur['ni'] or len(buf)>=total: break
                    cur=hdr(b,cur['ni'],cur['np'])
                if len(buf)>=total:
                    kl=struct.unpack_from('<I',buf,4)[0]
                    out.append((bytes(buf[8:8+kl]),bytes(buf[8+kl:total])))
            if h['next']==END: break
            pos=h['next']
    return out
if __name__=='__main__':
    import sys
    r=records(sys.argv[1])
    print(len(r),'Datensätze')
    for k,v in r[:40]: print(k.hex(), len(v), v[:24].hex())
