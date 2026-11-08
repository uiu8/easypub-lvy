"""生成自有几何图形字体，仅作映射测试；不复制任何商业或用户字体。"""
from pathlib import Path
import struct

def pack(fmt, *values):
    return struct.pack('>'+fmt, *values)

def simple(points, flags=None):
    xs, ys = zip(*points)
    data = pack('hhhhhHH', 1, min(xs), min(ys), max(xs), max(ys), len(points)-1, 0)
    data += bytes(flags or [1]*len(points))
    for axis in [xs, ys]:
        last=0
        for value in axis:
            data+=pack('h', value-last); last=value
    return data + bytes((-len(data))%4)

def checksum(data):
    data+=bytes((-len(data))%4)
    return sum(struct.unpack('>'+str(len(data)//4)+'I',data)) & 0xffffffff

def font(mapping, changed=False):
    glyphs=[b'', simple([(0,0),(100 if not changed else 90,0),(50,100)]),
            simple([(0,0),(120,0),(120,100),(0,100)]),
            simple([(0,0),(50,120),(100,0)],[1,0,1]),
            pack('hhhhhHHhh',-1,20,30,120,130,3,1,20,30)]
    offsets=[0]
    for glyph in glyphs: offsets.append(offsets[-1]+len(glyph))
    head=bytearray(54);struct.pack_into('>IIIIHH',head,0,0x10000,0x10000,0,0x5f0f3cf5,0,1000)
    struct.pack_into('>h',head,50,1)
    hhea=bytearray(36);struct.pack_into('>Ihhh',hhea,0,0x10000,800,-200,0);struct.pack_into('>H',hhea,34,len(glyphs))
    groups=b''.join(pack('III',cp,cp,gid) for cp,gid in sorted(mapping.items()))
    cmap=pack('HHHHI',0,1,3,10,12)+pack('HHIII',12,0,16+len(groups),0,len(mapping))+groups
    tables={'head':bytes(head),'hhea':bytes(hhea),'maxp':pack('IH',0x10000,len(glyphs))+bytes(26),
            'hmtx':pack('Hh',500,0)*len(glyphs),'loca':b''.join(pack('I',v) for v in offsets),'glyf':b''.join(glyphs),'cmap':cmap}
    count=len(tables);power=2**(count.bit_length()-1)
    header=pack('IHHHH',0x10000,count,power*16,power.bit_length()-1,count*16-power*16)
    offset=12+16*count;records=b'';body=b'';head_offset=0
    for tag,data in sorted(tables.items()):
        records+=tag.encode()+pack('III',checksum(data),offset,len(data))
        if tag=='head':head_offset=offset
        padded=data+bytes((-len(data))%4);body+=padded;offset+=len(padded)
    result=bytearray(header+records+body)
    struct.pack_into('>I',result,head_offset+8,(0xb1b0afba-checksum(result))&0xffffffff)
    return result

if __name__=='__main__':
    out=Path(__file__).resolve().parents[1]/'rust/crates/easypub_booksource/tests/fonts'
    out.mkdir(parents=True,exist_ok=True)
    correct={ord('甲'):1,ord('乙'):2,0x20000:3,ord('丙'):4}
    for name,data in {'correct.ttf':font(correct),'scrambled.ttf':font({0xe001:2,0xe002:1,0xe003:3,0xe004:4}),
                      'ambiguous.ttf':font({**correct,ord('丁'):1}),'different.ttf':font(correct,True)}.items():
        (out/name).write_bytes(data)
    print('Generated four synthetic fonts; no external input.')
