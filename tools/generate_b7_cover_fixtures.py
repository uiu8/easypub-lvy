"""用本机 Pillow 生成小型合成封面夹具，不下载图片。"""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[1] / 'samples' / 'b7-covers'
root.mkdir(parents=True, exist_ok=True)
Image.new('CMYK', (16, 12), (0, 180, 180, 0)).save(root / 'cmyk.jpg', quality=95)
image = Image.new('RGBA', (16, 12), (240, 20, 30, 0))
for y in range(3, 9):
    for x in range(4, 12):
        image.putpixel((x, y), (20, 180, 40, 128))
image.save(root / 'transparent.png')
Image.new('L', (16385, 1), 0).save(root / 'oversize.png')
(root / 'corrupt.png').write_bytes(b'not a PNG')
print(root)
