"""Independently compare generic and engine-specific EPUBs from the Rust probe."""
import hashlib
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile

root = Path(sys.argv[1])
report_path = Path(sys.argv[2])
ns = {"o": "http://www.idpf.org/2007/opf", "x": "http://www.w3.org/1999/xhtml",
      "n": "http://www.daisy.org/z3986/2005/ncx/"}


def read(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == len(set(archive.namelist()))
        return {name: archive.read(name) for name in archive.namelist()}


plain = read(root / "sample.epub")
engine = read(root / "kindling-input.epub")
assert set(engine) - set(plain) == {"EPUB/kindling.ncx"}
assert not set(plain) - set(engine)
for name in plain:
    if name != "EPUB/package.opf":
        assert plain[name] == engine[name], name


def package(files):
    doc = ET.fromstring(files["EPUB/package.opf"])
    items = {n.attrib["id"]: n.attrib for n in doc.findall("o:manifest/o:item", ns)}
    spine = doc.find("o:spine", ns)
    return doc, items, spine, [items[n.attrib["idref"]]["href"] for n in spine]


generic_doc, _, _, generic_order = package(plain)
engine_doc, items, spine, engine_order = package(engine)
assert "cover.xhtml" in generic_order
assert engine_order == [name for name in generic_order if name != "cover.xhtml"]
assert items[spine.attrib["toc"]]["href"] == "kindling.ncx"
assert items[spine.attrib["toc"]]["media-type"] == "application/x-dtbncx+xml"
assert sum("cover-image" in n.get("properties", "").split() for n in items.values()) == 1
# The exporter timestamps each serialization separately; all other metadata must match.
for doc in (generic_doc, engine_doc):
    metadata = doc.find("o:metadata", ns)
    for node in list(metadata):
        if node.attrib.get("property") == "dcterms:modified":
            metadata.remove(node)
assert ET.tostring(generic_doc.find("o:metadata", ns)) == ET.tostring(engine_doc.find("o:metadata", ns))
nav = ET.fromstring(engine["EPUB/nav.xhtml"])
toc = next(n for n in nav.findall(".//x:nav", ns)
           if "toc" in n.attrib.get("{http://www.idpf.org/2007/ops}type", "").split())
ncx = ET.fromstring(engine["EPUB/kindling.ncx"])


def nav_tree(ol):
    result = []
    for li in ol.findall("x:li", ns):
        a = li.find("x:a", ns)
        child = li.find("x:ol", ns)
        result.append(("".join(a.itertext()), a.attrib["href"], nav_tree(child) if child is not None else []))
    return result


def ncx_tree(parent):
    return [(n.find("n:navLabel/n:text", ns).text, n.find("n:content", ns).attrib["src"], ncx_tree(n))
            for n in parent.findall("n:navPoint", ns)]


assert nav_tree(toc.find("x:ol", ns)) == ncx_tree(ncx.find("n:navMap", ns))
points = ncx.findall(".//n:navPoint", ns)
assert [int(n.attrib["playOrder"]) for n in points] == list(range(1, len(points) + 1))
for point in points:
    target, _, fragment = point.find("n:content", ns).attrib["src"].partition("#")
    doc = ET.fromstring(engine["EPUB/" + target])
    assert not fragment or any(n.attrib.get("id") == fragment for n in doc.iter())
eol = {"lf": "\n", "cr": "\r", "crlf": "\r\n", "none": ""}
text = "".join("".join(n.itertext()) + eol[n.attrib["data-eol"]]
               for name in engine_order for n in ET.fromstring(engine["EPUB/" + name]).iter()
               if n.attrib.get("data-source") == "true")
assert text.encode("utf-8") == (root / "final-text.txt").read_bytes()
report = {"passed": True, "input": str(root / "kindling-input.epub"),
          "sha256": hashlib.sha256((root / "kindling-input.epub").read_bytes()).hexdigest(),
          "unchanged_original_entries": len(plain) - 1, "navigation_entries": len(points),
          "hierarchy_and_links_preserved": True, "exact_final_text": True,
          "cover_resource_preserved": True, "cover_removed_from_spine_only": True,
          "reader_verified": False}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(report, ensure_ascii=False))
