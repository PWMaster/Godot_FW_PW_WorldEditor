# Layout der Quest-Strukturen aus TaskTempl.h (pack 1, WIN32: 4-Byte-Füllfeld vor jedem 4-Byte-Zeiger)
# Eingaben (UTF-8, siehe README.txt): TaskTempl.h und task_all_h.txt (alle Header von SMElementClient/Task)
import re, os
BASE = os.path.dirname(os.path.abspath(__file__)) + '/'
H = open(os.environ.get('TASKTEMPL_H', BASE + 'TaskTempl.h'), encoding='utf-8').read()
ALLH = open(os.environ.get('TASK_HEADERS', BASE + 'task_all_h.txt'), encoding='utf-8').read()
DEFINES = {'WIN32': 1, '__i386__': 1}


def preprocess(src):
    out = []
    stack = [True]
    for line in src.split('\n'):
        s = line.strip()
        if s.startswith('#if defined') or s.startswith('#if '):
            names = re.findall(r'defined\s*\(?\s*(\w+)', s)
            cond = any(n in DEFINES for n in names) if names else False
            stack.append(stack[-1] and cond)
            continue
        if s.startswith('#ifdef'):
            stack.append(stack[-1] and s.split()[1] in DEFINES)
            continue
        if s.startswith('#ifndef'):
            stack.append(stack[-1] and s.split()[1] not in DEFINES)
            continue
        if s.startswith('#else'):
            top = stack.pop()
            stack.append(stack[-1] and not top)
            continue
        if s.startswith('#endif'):
            stack.pop()
            continue
        if stack[-1]:
            out.append(line)
    return '\n'.join(out)


SRC = re.sub(r'/\*.*?\*/', '', H, flags=re.S)
SRC = re.sub(r'//[^\n]*', '', SRC)
SRC = preprocess(SRC)
CONST = {k: v for k, v in re.findall(r'#define\s+(\w+)\s+(\(?[-0-9][0-9xXa-fA-F +*()-]*\)?)\s*(?://.*)?$', ALLH + '\n' + SRC, re.M)}


def ev(e):
    for _ in range(4):
        for k, v in CONST.items():
            e = re.sub(r'\b%s\b' % k, v, e)
    return int(eval(e, {}, {}))


PRIM = {'int': 4, 'unsigned int': 4, 'unsigned': 4, 'long': 4, 'unsigned long': 4, 'float': 4, 'double': 8, 'short': 2,
        'unsigned short': 2, 'char': 1, 'unsigned char': 1, 'signed char': 1, 'bool': 1, 'task_char': 2, 'size32_task': 4,
        'int64_task': 8, 'int64_t': 8, '__int64': 8, 'long long': 8, 'unsigned long long': 8, 'DWORD': 4, 'BYTE': 1,
        'WORD': 2, 'time_t': 4, 'wchar_t': 2}
ENUMS = set(re.findall(r'enum\s+(\w+)', SRC))


def struct_body(name):
    m = re.search(r'\bstruct\s+%s\s*(?::[^{]*)?\{' % name, SRC)
    if not m:
        raise Exception('Struktur fehlt: ' + name)
    i = m.end()
    d = 1
    j = i
    while d:
        if SRC[j] == '{':
            d += 1
        elif SRC[j] == '}':
            d -= 1
        j += 1
    return SRC[i:j - 1]


def members(body):
    # Anweisungen auf oberster Ebene, Funktionsrümpfe überspringen
    out = []
    buf = ''
    d = 0
    i = 0
    while i < len(body):
        c = body[i]
        if c == '{':
            if d == 0 and '(' in buf:
                k = i
                dd = 0
                while True:
                    if body[k] == '{':
                        dd += 1
                    elif body[k] == '}':
                        dd -= 1
                        if dd == 0:
                            break
                    k += 1
                i = k + 1
                buf = ''
                continue
            d += 1
            buf += c
        elif c == '}':
            d -= 1
            buf += c
        elif c == ';' and d == 0:
            s = buf.strip()
            buf = ''
            if s and '(' not in s and not s.startswith(('typedef', 'enum', 'friend', 'static')):
                out.append(s)
        else:
            buf += c
        i += 1
    return out


LAY = {}


def layout(name):
    if name in LAY:
        return LAY[name]
    off = 0
    fields = []
    for s in members(struct_body(name)):
        s = re.sub(r'\s+', ' ', s)
        s = re.sub(r'^(mutable|volatile) ', '', s)
        if s.startswith('union'):
            inner = s[s.index('{') + 1:s.rindex('}')]
            best = 0
            for alt in re.findall(r'struct\s*\{([^}]*)\}|([^;{}]+;)', inner):
                body = alt[0] if alt[0] else alt[1]
                tot = 0
                for decl in [x.strip() for x in body.split(';') if x.strip()]:
                    mm = re.match(r'((?:unsigned )?\w+)\s+(\w+)((?:\s*\[[^\]]+\])*)$', decl)
                    nn = 1
                    for d in re.findall(r'\[([^\]]+)\]', mm.group(3)):
                        nn *= ev(d)
                    tot += PRIM[mm.group(1)] * nn
                best = max(best, tot)
            nm = s[s.rindex('}') + 1:].strip() or '_union%d' % off
            fields.append((nm, 'raw', off, 1, best))
            off += best
            continue
        if s.startswith('struct') and '{' in s:
            raise Exception('verschachtelte Struktur in ' + name + ': ' + s[:60])
        m = re.match(r'((?:const |unsigned |signed )*(?:long long|\w+)(?: int)?)\s*(\*?)\s*(\w+)((?:\s*\[[^\]]+\])*)$', s)
        if not m:
            raise Exception('Deklaration? ' + name + ': ' + s)
        t, ptr, fn, dims = m.groups()
        t = t.strip()
        n = 1
        for d in re.findall(r'\[([^\]]+)\]', dims):
            n *= ev(d)
        if ptr:
            sz = 4
            kind = 'ptr'
        elif t in PRIM:
            sz = PRIM[t]
            kind = t
        elif t in ENUMS:
            sz = 4
            kind = 'enum'
        else:
            sub = layout(t)
            sz = sub['size']
            kind = t
        fields.append((fn, kind, off, n, sz))
        off += sz * n
    LAY[name] = {'size': off, 'fields': fields}
    return LAY[name]
