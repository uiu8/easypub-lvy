"""Validate generated navigation proof with an independent strict XML parser."""
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
ns = {"x": "http://www.w3.org/1999/xhtml"}
source = (root / "source.txt").read_text(encoding="utf-8")
rows = []
for case in sorted(root.iterdir()):
    if not case.is_dir():
        continue
    docs = {p.name: ET.parse(p).getroot() for p in case.glob("*.xhtml")}
    anchors = {}
    for name, doc in docs.items():
        ids = [e.attrib["id"] for e in doc.iter() if "id" in e.attrib]
        assert len(ids) == len(set(ids)), (name, "duplicate IDs")
        anchors[name] = set(ids)
    count = 0
    for name, doc in docs.items():
        for link in doc.findall(".//x:a", ns):
            file, fragment = link.attrib["href"].split("#", 1)
            assert fragment in anchors[file], (name, file, fragment)
            count += 1
    def text_without_navigation(element):
        result = element.text or ""
        for child in element:
            if child.tag != "{" + ns["x"] + "}nav":
                result += text_without_navigation(child)
            result += child.tail or ""
        return result
    body = docs["body.xhtml"].find("x:body/x:div", ns)
    assert text_without_navigation(body) == source, (case.name, "body changed")
    assert ("nav.xhtml" in docs) == (case.name[0] == "1")
    assert ("toc.xhtml" in docs) == (case.name[1] == "1")
    rows.append({"case": case.name, "links": count, "xml_valid": True,
                 "targets_unique_and_closed": True, "body_preserved_after_xml_newline_normalization": True,
                 "sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(case.glob("*.xhtml"))}})
assert len(rows) == 8
report = {"passed": True, "cases": rows, "artifact_directory": str(root),
          "epub_export": False, "reader_verified": False,
          "scope": "standalone navigation XHTML proof, not full production layout"}
Path("docs/evidence/r5-navigation-documents.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps({"passed": True, "cases": len(rows), "links": sum(r["links"] for r in rows)}))
