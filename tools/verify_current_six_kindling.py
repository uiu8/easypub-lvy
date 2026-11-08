"""Independently extract each matrix AZW3 and compare text and navigation to EPUB."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import unquote
from xml.etree import ElementTree as ET
import hashlib
import json
import subprocess
import sys
import zipfile

root = Path(sys.argv[1]).resolve()
ns = {'o':'http://www.idpf.org/2007/opf','n':'http://www.daisy.org/z3986/2005/ncx/'}
def verify(path):
    e=json.loads(path.read_text(encoding='utf-8'))
    azw=Path(next(o['path'] for o in e['outputs'] if o['format']=='AZW3'))
    epub=Path(next(o['path'] for o in e['outputs'] if o['format']=='EPUB'))
    destination=path.parent/'calibre-extracted'
    if not destination.exists():
        p=subprocess.run(['C:/Program Files/Calibre2/calibre-debug.exe','-x',str(azw),str(destination)],capture_output=True,timeout=120,creationflags=subprocess.CREATE_NO_WINDOW)
        (path.parent/'calibre.log').write_bytes(p.stdout+p.stderr)
        assert p.returncode==0, path
    def pages(opf, load):
        manifest={i.attrib['id']:i.attrib['href'] for i in opf.findall('o:manifest/o:item',ns)}
        return {manifest[i.attrib['idref']]:ET.fromstring(load(manifest[i.attrib['idref']])) for i in opf.findall('o:spine/o:itemref',ns)}
    def text(docs):
        return [''.join(n.itertext()) for doc in docs.values() for n in doc.iter() if n.attrib.get('data-source')=='true']
    def tree(parent,docs):
        result=[]
        for n in parent.findall('n:navPoint',ns):
            label=n.find('n:navLabel/n:text',ns).text or ''
            file,_,anchor=unquote(n.find('n:content',ns).attrib['src']).partition('#')
            node=next(v for v in docs[file].iter() if v.attrib.get('id')==anchor) if anchor else docs[file]
            result.append((label,''.join(node.itertext()),tree(n,docs)))
        return result
    def epub_tree(parent,docs):
        result=[]
        x='{http://www.w3.org/1999/xhtml}'
        if parent is None:
            return result
        for n in parent.findall(x+'li'):
            a=n.find(x+'a')
            file,_,anchor=unquote(a.attrib['href']).partition('#')
            node=next(v for v in docs[file].iter() if v.attrib.get('id')==anchor) if anchor else docs[file]
            result.append((''.join(a.itertext()),''.join(node.itertext()),epub_tree(n.find(x+'ol'),docs)))
        return result
    final_docs=pages(ET.parse(destination/'metadata.opf').getroot(),lambda f:(destination/f).read_bytes())
    final_tree=tree(ET.parse(destination/'toc.ncx').getroot().find('n:navMap',ns),final_docs)
    with zipfile.ZipFile(epub) as z:
        opf_name=next(n for n in z.namelist() if n.endswith('.opf'))
        base=Path(opf_name).parent
        original_docs=pages(ET.fromstring(z.read(opf_name)),lambda f:z.read((base/f).as_posix()))
        nav=next(n for n in z.namelist() if n.endswith('/nav.xhtml'))
        nav_doc=ET.fromstring(z.read(nav))
        original_tree=epub_tree(nav_doc.find('.//{http://www.w3.org/1999/xhtml}nav/{http://www.w3.org/1999/xhtml}ol'),original_docs)
        assert text(final_docs)==text(original_docs),(path,'text differs')
        if len(final_tree)==len(original_tree)+1:
            first=ET.parse(destination/'toc.ncx').getroot().find('n:navMap/n:navPoint/n:content',ns).attrib['src'].split('#')[0]
            assert not any(n.attrib.get('data-source')=='true' for n in final_docs[first].iter())
            final_tree=final_tree[1:]
        assert final_tree==original_tree,(path,'navigation differs')
    return {'case':path.parent.name,'passed':True,'azw3_sha256':hashlib.sha256(azw.read_bytes()).hexdigest(),'source_lines':len(text(final_docs)),'navigation_and_landing_match':True}

with ThreadPoolExecutor(max_workers=4) as pool:
    results=list(pool.map(verify,sorted(root.glob('*/evidence.json'))))
assert len(results)==44
(root/'kindling-independent.json').write_text(json.dumps({'passed':True,'cells':results},ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'passed':True,'azw3_files':len(results),'source_lines':sum(r['source_lines'] for r in results)}))
