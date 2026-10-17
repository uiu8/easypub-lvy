"""Independent XML, exact source-line and resource closure checks; not reader acceptance."""
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
docs = {p.name: ET.parse(p).getroot() for p in root.glob("*.xhtml")}
ns = {"x": "http://www.w3.org/1999/xhtml"}
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
order = json.loads((root / "reading-order.json").read_text(encoding="utf-8"))
assert order == ["cover.xhtml", "title.xhtml", "toc.xhtml", "body.xhtml"]
anchors = {}
for name, doc in docs.items():
    ids = [e.attrib["id"] for e in doc.iter() if "id" in e.attrib]
    assert len(ids) == len(set(ids)), (name, "duplicate IDs")
    anchors[name] = set(ids)
    styles = [e.attrib["href"] for e in doc.findall("x:head/x:link", ns)]
    assert styles == manifest["stylesheet_order"]
    assert not doc.findall(".//x:script", ns)
links = 0
for name, doc in docs.items():
    for element in doc.iter():
        if element.tag.endswith("}a"):
            file, anchor = element.attrib["href"].split("#", 1)
            assert anchor in anchors[file], (name, file, anchor)
            links += 1
        if element.tag.endswith(("}img", "}link")):
            ref = element.attrib.get("src", element.attrib.get("href"))
            assert ref and Path(ref).name == ref and (root / ref).is_file(), ref
            content_hash = hashlib.sha256((root / ref).read_bytes()).hexdigest()
            assert ref.split(".")[0] == content_hash, ref
eol = {"crlf": "\r\n", "cr": "\r", "lf": "\n", "none": ""}
source_nodes = [n for n in docs["body.xhtml"].iter() if n.attrib.get("data-source") == "true"]
reconstructed = "".join("".join(n.itertext()) + eol[n.attrib["data-eol"]] for n in source_nodes)
assert reconstructed.encode("utf-8") == (root / "final-text.txt").read_bytes()
figures = docs["body.xhtml"].findall(".//x:figure", ns)
assert len(figures) == len(manifest["placements"])
for figure, placement in zip(figures, manifest["placements"]):
    assert figure.find("x:img", ns).attrib["src"] == placement["resource_id"]
    assert figure.find("x:figcaption", ns).text == placement["caption"]
report = {"passed": True, "artifact_directory": str(root), "pages": len(docs),
          "links": links, "source_lines": len(source_nodes), "exact_utf8_reconstruction": True,
          "styles_and_images_resolve_by_hash": True, "reading_order": order,
          "epub_export": False, "reader_verified": False}
Path("docs/evidence/r5-publication-documents.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(report, ensure_ascii=False))
