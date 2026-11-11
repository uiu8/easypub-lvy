import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/kindle_preview_server.dart';

/// 只含 name 与 OS/2 表的假字体：名字照 Kindle 固件字体的内部名写，
/// 不用真的 Kindle 字体文件。
Uint8List fakeFont(
  Map<int, String> names, {
  int weight = 400,
  bool ttc = false,
}) {
  final name = BytesBuilder();
  final strings = BytesBuilder();
  final entries = names.entries.toList();
  final head = ByteData(6)
    ..setUint16(0, 0)
    ..setUint16(2, entries.length)
    ..setUint16(4, 6 + entries.length * 12);
  name.add(head.buffer.asUint8List());
  for (final e in entries) {
    final text = ByteData(e.value.length * 2);
    for (var i = 0; i < e.value.length; i++) {
      text.setUint16(i * 2, e.value.codeUnitAt(i));
    }
    final record = ByteData(12)
      ..setUint16(0, 3)
      ..setUint16(2, 1)
      ..setUint16(4, 0x409)
      ..setUint16(6, e.key)
      ..setUint16(8, text.lengthInBytes)
      ..setUint16(10, strings.length);
    name.add(record.buffer.asUint8List());
    strings.add(text.buffer.asUint8List());
  }
  name.add(strings.takeBytes());
  final nameBytes = name.takeBytes();
  final os2 = (ByteData(8)..setUint16(4, weight)).buffer.asUint8List();
  final base = ttc ? 16 : 0;
  final dir = 12 + 2 * 16;
  final out = BytesBuilder();
  if (ttc) {
    out.add(ascii.encode('ttcf'));
    out.add(
      (ByteData(12)
            ..setUint32(4, 1)
            ..setUint32(8, 16))
          .buffer
          .asUint8List()
          .sublist(0, 12),
    );
  }
  final header = ByteData(dir)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, 2);
  void table(int i, String tag, int offset, int length) {
    for (var j = 0; j < 4; j++) {
      header.setUint8(12 + i * 16 + j, tag.codeUnitAt(j));
    }
    header
      ..setUint32(12 + i * 16 + 8, offset)
      ..setUint32(12 + i * 16 + 12, length);
  }

  table(0, 'name', base + dir, nameBytes.length);
  table(1, 'OS/2', base + dir + nameBytes.length, os2.length);
  out
    ..add(header.buffer.asUint8List())
    ..add(nameBytes)
    ..add(os2);
  return out.takeBytes();
}

void main() {
  test('认出 Kindle 自带的中文字体：按内部字族名，分简繁与粗细', () {
    expect(kindleFontOf(fakeFont({1: 'STBShusong', 2: 'Regular'})), {
      'face': 'song',
      'script': 'sc',
      'bold': false,
    });
    // 固件的简体粗宋体字重字段仍写 400，靠名字认出粗体。
    expect(
      kindleFontOf(fakeFont({1: 'STBShusong-Bold', 2: 'Regular', 17: 'Bold'})),
      {'face': 'song', 'script': 'sc', 'bold': true},
    );
    expect(kindleFontOf(fakeFont({1: 'STHeitiTC', 2: 'Bold'}, weight: 700)), {
      'face': 'hei',
      'script': 'tc',
      'bold': true,
    });
    expect(kindleFontOf(fakeFont({1: 'STSongTC', 2: 'Regular'})), {
      'face': 'song',
      'script': 'tc',
      'bold': false,
    });
    expect(
      kindleFontOf(fakeFont({1: 'STKaiti', 2: 'Regular'}))?['face'],
      'kai',
    );
    expect(
      kindleFontOf(fakeFont({1: 'STZhongyuan', 2: 'Regular'}))?['face'],
      'yuan',
    );
    expect(
      kindleFontOf(fakeFont({1: 'STHeiti', 2: 'Regular'}, ttc: true))?['face'],
      'hei',
    );
    expect(kindleFontOf(fakeFont({1: 'Arial', 2: 'Regular'})), isNull);
    expect(kindleFontOf(utf8.encode('不是字体')), isNull);
    expect(kindleFontOf(const []), isNull);
  });

  test('批量导入 Kindle 字体：清单记字体种类，同一种只留最新一份', () async {
    final root = (await Directory('../artifacts').createTemp('v128-pv-'))
        .absolute
        .path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final server = KindlePreviewServer(
      pluginDirectory: '$root/plugin',
      state: () => {'title': '样书'},
      render: (_, _) => throw const FormatException('不用'),
      metrics: (_) => const {},
      apply: (_) async => null,
      fontDirectory: '$root/preview-fonts',
    );
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final client = HttpClient();
    try {
      final base = await server.start();
      Future<Map<String, dynamic>> post(
        String path,
        List<int> bytes,
        String name,
      ) async {
        final request = await client.postUrl(base.resolve(path));
        request.headers.set('X-Font-Name', Uri.encodeComponent(name));
        request.add(bytes);
        final response = await request.close();
        expect(response.statusCode, 200);
        return jsonDecode(await utf8.decodeStream(response))
            as Map<String, dynamic>;
      }

      final song = await post(
        'api/font-import',
        fakeFont({1: 'STBShusong', 2: 'Regular'}),
        'STSongMedium.ttf',
      );
      expect(song['font']['kindle'], {
        'face': 'song',
        'script': 'sc',
        'bold': false,
      });
      final bold = await post(
        'api/font-import',
        fakeFont({1: 'STBShusong-Bold', 17: 'Bold'}),
        'STSongBold.ttf',
      );
      expect(bold['fonts'], hasLength(2));
      // 再导入另一份简体常规宋体：替换旧的，旧文件删掉。
      final again = await post(
        'api/font-import',
        fakeFont({1: 'STBShusong', 2: 'Regular', 4: 'STBShusong'}),
        '宋体另一份.ttf',
      );
      final fonts = again['fonts'] as List;
      expect(fonts, hasLength(2));
      expect(
        File('$root/preview-fonts/${song['font']['file']}').existsSync(),
        false,
      );
      final other = await post(
        'api/font-import',
        fakeFont({1: 'Arial', 2: 'Regular'}),
        '我的字体.ttf',
      );
      expect(other['font'].containsKey('kindle'), false);
      // 重开预览时清单里仍带字体种类。
      final state = await (await client.getUrl(base.resolve('api/state')))
          .close();
      final list =
          (jsonDecode(await utf8.decodeStream(state)) as Map)['fonts'] as List;
      expect(list, hasLength(3));
      expect(
        [for (final f in list) (f as Map)['kindle']?['bold']],
        [true, false, null],
      );
    } finally {
      client.close(force: true);
      await server.close();
    }
  });

  test('V128 以前导入的 Kindle 字体：重开预览时认出，最后导入的一份对应到宋体，上次的选择改到宋体', () async {
    final root = (await Directory('../artifacts').createTemp('v128-old-'))
        .absolute
        .path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final dir = Directory('$root/preview-fonts')..createSync();
    // 两份简体常规宋体（旧的一份、后导入的一份）与一个普通字体，都没有字体种类。
    final files = {
      'aaaaaaaaaaaaaaaa': fakeFont({1: 'STBShusong', 2: 'Regular', 4: 'old'}),
      'bbbbbbbbbbbbbbbb': fakeFont({1: 'Arial', 2: 'Regular'}),
      'cccccccccccccccc': fakeFont({1: 'STBShusong', 2: 'Regular'}),
    };
    for (final e in files.entries) {
      File('${dir.path}/${e.key}.ttf').writeAsBytesSync(e.value);
    }
    File('${dir.path}/fonts.json').writeAsStringSync(
      jsonEncode({
        'fonts': [
          for (final id in files.keys)
            {'id': id, 'name': id, 'file': '$id.ttf'},
        ],
        // 选的是较早的那份（用户时导入的宋体）。
        'selected': 'user:aaaaaaaaaaaaaaaa',
      }),
    );
    final server = KindlePreviewServer(
      pluginDirectory: '$root/plugin',
      state: () => {'title': '样书'},
      render: (_, _) => throw const FormatException('不用'),
      metrics: (_) => const {},
      apply: (_) async => null,
      fontDirectory: dir.path,
    );
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final client = HttpClient();
    try {
      final base = await server.start();
      final response = await (await client.getUrl(base.resolve('api/state')))
          .close();
      final state = jsonDecode(await utf8.decodeStream(response)) as Map;
      final fonts = state['fonts'] as List;
      expect(
        [for (final f in fonts) (f as Map)['kindle']?['face']],
        [null, null, 'song'],
      );
      expect([for (final f in fonts) (f as Map)['plain']], [true, true, null]);
      expect(state['reader_font'], 'song');
      // 认过的结果记进清单，下次不再读字体文件。
      final saved =
          jsonDecode(File('${dir.path}/fonts.json').readAsStringSync()) as Map;
      expect(saved['selected'], 'song');
      expect((saved['fonts'] as List).last['kindle']['face'], 'song');
    } finally {
      client.close(force: true);
      await server.close();
    }
  });
}
