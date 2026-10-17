"""OUT-087: inspect actual AZW3 identity and cover records without a device/library.

Run with Python, or calibre-debug -e this_file -- book.azw3 --calibre
to also check the installed Calibre device driver's thumbnail filename.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import uuid


def u32(data, at=0):
    return struct.unpack_from('>I', data, at)[0]


def read(path):
    data = path.read_bytes()
    assert data[60:68] == b'BOOKMOBI'
    count = struct.unpack_from('>H', data, 76)[0]
    offsets = [u32(data, 78 + 8 * i) for i in range(count)] + [len(data)]
    records = [data[a:b] for a, b in zip(offsets, offsets[1:])]
    header = records[0]
    assert header[16:20] == b'MOBI' and u32(header, 36) == 8
    exth = header[16 + u32(header, 20):]
    assert exth[:4] == b'EXTH'
    fields, at = {}, 12
    for _ in range(u32(exth, 8)):
        kind, size = u32(exth, at), u32(exth, at + 4)
        assert size >= 8 and at + size <= u32(exth, 4)
        fields[kind] = exth[at + 8:at + size]
        at += size
    return records, fields


def inspect(path):
    records, fields = read(path)
    content_id = fields.get(113, b'').decode('utf-8')
    content_type = fields.get(501, b'').decode('utf-8')
    first_image = u32(records[0], 108)
    images = {}
    for name, key in [('cover', 201), ('thumbnail', 202)]:
        image = records[first_image + u32(fields[key])]
        assert image.startswith((b'\xff\xd8\xff', b'\x89PNG\r\n\x1a\n')), name
        images[name] = {'bytes': len(image), 'sha256': hashlib.sha256(image).hexdigest()}
    return {
        'file': str(path.resolve()),
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'content_type': content_type,
        'content_id': content_id,
        'title': fields[503].decode('utf-8'),
        'author': fields[100].decode('utf-8'),
        'thumbnail_filename': f'thumbnail_{content_id}_{content_type}_portrait.jpg'
            if content_id and content_type else '',
        'images': images,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('book', type=Path)
    parser.add_argument('--inspect-only', action='store_true')
    parser.add_argument('--calibre', action='store_true')
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--same-identity', type=Path)
    args = parser.parse_args()
    report = inspect(args.book)
    if not args.inspect_only:
        assert report['content_type'] == 'EBOK', report
        assert str(uuid.UUID(report['content_id'])) == report['content_id'], report
    if args.baseline:
        assert read(args.book)[0][1:] == read(args.baseline)[0][1:]
        report['all_content_records_identical_to_baseline'] = True
    if args.same_identity:
        other = inspect(args.same_identity)
        assert report['content_id'] == other['content_id']
        assert report['thumbnail_filename'] == other['thumbnail_filename']
        report['repeat_identity_stable'] = True
    if args.calibre:
        from calibre.devices.kindle.driver import KINDLE2, thumbnail_filename
        from calibre.ebooks.metadata.mobi import get_metadata
        with args.book.open('rb') as stream:
            actual = thumbnail_filename(stream)
            stream.seek(0)
            metadata = get_metadata(stream)
        assert actual == report['thumbnail_filename'], (actual, report)
        report['installed_calibre_thumbnail_filename'] = actual
        assert metadata.cover_data and metadata.cover_data[1]
        report['calibre_extracted_cover_bytes'] = len(metadata.cover_data[1])
        # Run the real upload method against an isolated temporary directory;
        # no USB discovery, user library, device database or plugin settings.
        records, fields = read(args.book)
        thumbnail = records[u32(records[0], 108) + u32(fields[202])]
        with tempfile.TemporaryDirectory(prefix='easypub-calibre-cover-') as directory:
            root = Path(directory)
            (root / 'system/thumbnails').mkdir(parents=True)
            driver = object.__new__(KINDLE2)
            driver._main_prefix = directory
            driver.upload_kindle_thumbnail(
                SimpleNamespace(thumbnail=(330, 440, thumbnail)), str(args.book))
            if actual:
                for folder in ['system/thumbnails', 'amazon-cover-bug']:
                    assert (root / folder / actual).read_bytes() == thumbnail
            else:
                assert not list((root / 'system/thumbnails').iterdir())
            report['calibre_simulated_device_cover_written'] = bool(actual)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
