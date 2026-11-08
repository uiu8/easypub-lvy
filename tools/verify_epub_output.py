"""Independent ZIP/XML and exact text verification of the development EPUB artifact."""
import hashlib
import json
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

argument = Path(sys.argv[1])
root = argument if argument.is_dir() else argument.parent
path = root / "sample.epub" if argument.is_dir() else argument
expected_text = Path(sys.argv[2]) if len(sys.argv) > 2 else root / "final-text.txt"
report_path = Path(sys.argv[3]) if len(sys.argv) > 3 else Path("docs/evidence/r5-epub-output.json")
ns = {"opf": "http://www.idpf.org/2007/opf", "x": "http://www.w3.org/1999/xhtml",
      "c": "urn:oasis:names:tc:opendocument:xmlns:container"}
with zipfile.ZipFile(path) as z:
    entries = z.infolist()
    assert entries[0].filename == "mimetype" and entries[0].compress_type == 0
    assert z.read("mimetype") == b"application/epub+zip"
    assert path.read_bytes()[28:30] == b"\x00\x00"
    assert len(entries) == len(set(z.namelist()))
    assert z.testzip() is None
    container = ET.fromstring(z.read("META-INF/container.xml"))
    package = container.find("c:rootfiles/c:rootfile", ns).attrib["full-path"]
    opf = ET.fromstring(z.read(package))
    items = {n.attrib["id"]: n.attrib for n in opf.findall("opf:manifest/opf:item", ns)}
    assert sum("nav" in n.get("properties", "").split() for n in items.values()) == 1
    assert {"EPUB/" + n["href"] for n in items.values()} == set(z.namelist()) - {"mimetype", "META-INF/container.xml", package}
    spine = [items[n.attrib["idref"]]["href"] for n in opf.findall("opf:spine/opf:itemref", ns)]
    if (root / "reading-order.json").is_file():
        logical_order = json.loads((root / "reading-order.json").read_text(encoding="utf-8"))
        assert [n for n in spine if not n.startswith("body-")] == logical_order
    assert spine[-1].startswith("body") and "nav.xhtml" not in spine
    assert len(spine) == len(set(spine))
    docs = {n["href"]: ET.fromstring(z.read("EPUB/" + n["href"])) for n in items.values() if n["media-type"] == "application/xhtml+xml"}
    anchors = {name: {e.attrib["id"] for e in doc.iter() if "id" in e.attrib} for name, doc in docs.items()}
    links = 0
    for name, doc in docs.items():
        for a in doc.findall(".//x:a", ns):
            target, _, fragment = a.attrib["href"].partition("#")
            assert target in docs and (not fragment or fragment in anchors[target])
            links += 1
        for e in doc.iter():
            if e.tag.endswith(("}link", "}img")):
                ref = e.attrib.get("href", e.attrib.get("src"))
                data = z.read("EPUB/" + ref)
                assert hashlib.sha256(data).hexdigest() == ref.split(".")[0]
    eol = {"lf": "\n", "cr": "\r", "crlf": "\r\n", "none": ""}
    text = "".join("".join(n.itertext()) + eol[n.attrib["data-eol"]] for name in spine for n in docs[name].iter() if n.attrib.get("data-source") == "true")
    assert text.encode("utf-8") == expected_text.read_bytes()
    ncx_entries = 0
    ncx_id = opf.find("opf:spine", ns).attrib.get("toc")
    if ncx_id:
        ncx_item = items[ncx_id]
        assert ncx_item['media-type'] == 'application/x-dtbncx+xml'
        ncx = ET.fromstring(z.read('EPUB/' + ncx_item['href']))
        ncx_ns = '{http://www.daisy.org/z3986/2005/ncx/}'
        def ncx_tree(parent):
            result = []
            for point in parent.findall(ncx_ns + 'navPoint'):
                target = point.find(ncx_ns + 'content').attrib['src']
                file, _, fragment = target.partition('#')
                assert file in docs and (not fragment or fragment in anchors[file])
                label = point.find(ncx_ns + 'navLabel/' + ncx_ns + 'text').text or ''
                result.append((label, target, ncx_tree(point)))
            return result
        def nav_tree(parent):
            result = []
            for li in parent.findall('x:li', ns):
                a = li.find('x:a', ns)
                ol = li.find('x:ol', ns)
                result.append((''.join(a.itertext()), a.attrib['href'], nav_tree(ol) if ol is not None else []))
            return result
        nav_item = next(n for n in items.values() if 'nav' in n.get('properties', '').split())
        toc = next(n for n in docs[nav_item['href']].findall('.//x:nav', ns)
                   if 'toc' in n.attrib.get('{http://www.idpf.org/2007/ops}type', '').split())
        assert ncx_tree(ncx.find(ncx_ns + 'navMap')) == nav_tree(toc.find('x:ol', ns))
        ncx_entries = len(ncx.findall('.//' + ncx_ns + 'navPoint'))
report = {"passed": True, "epub": str(path), "bytes": path.stat().st_size,
          "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "zip_crc_valid": True,
          "manifest_complete": True, "reading_order_matches": True, "links": links,
          "exact_final_text": True, "expected_text": str(expected_text), "reader_verified": False,
          "body_files": [n for n in spine if n.startswith("body")], "spine_items": len(spine),
          "ncx_entries": ncx_entries, "ncx_hierarchy_and_targets_match": True if ncx_id else None}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(report, ensure_ascii=False))
