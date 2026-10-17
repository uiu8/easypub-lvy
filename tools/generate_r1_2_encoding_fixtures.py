from pathlib import Path

root = Path(__file__).resolve().parents[1] / "fixtures" / "r1-2"
root.mkdir(parents=True, exist_ok=True)
text = "第一章 开始😀\r\n正文保留\n第二章 继续\r尾行"
(root / "utf16le.txt").write_bytes(b"\xff\xfe" + text.encode("utf-16-le"))
(root / "utf16be.txt").write_bytes(b"\xfe\xff" + text.encode("utf-16-be"))
(root / "utf32le.txt").write_bytes(b"\xff\xfe\x00\x00" + text.encode("utf-32-le"))
(root / "utf32be.txt").write_bytes(b"\x00\x00\xfe\xff" + text.encode("utf-32-be"))
cp936_text = "第一章 开始\r\n正文保留\n第二章 继续\r尾行"
(root / "cp936.txt").write_bytes(cp936_text.encode("cp936"))
