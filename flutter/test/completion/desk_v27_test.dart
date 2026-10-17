import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

class _NoPicker implements BookFilePicker {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Desktop implements ConversionDesktop {
  @override
  Future<String?> bundledConverter() async => null;
  @override
  Future<String?> chooseConverter() async => null;
  @override
  Future<void> openDirectory(String path) async {}
  @override
  Future<void> openOutput(String path) async {}
}

/// 读 zip 里的一个文件（按本地文件头；存储或 deflate）。
List<int>? _zipEntry(List<int> zip, String name) {
  final data = ByteData.sublistView(Uint8List.fromList(zip));
  var at = 0;
  while (at + 30 <= zip.length &&
      data.getUint32(at, Endian.little) == 0x04034b50) {
    final method = data.getUint16(at + 8, Endian.little);
    final size = data.getUint32(at + 18, Endian.little);
    final nameLength = data.getUint16(at + 26, Endian.little);
    final extra = data.getUint16(at + 28, Endian.little);
    final entry = utf8.decode(zip.sublist(at + 30, at + 30 + nameLength));
    final start = at + 30 + nameLength + extra;
    final body = zip.sublist(start, start + size);
    if (entry == name) {
      return method == 0 ? body : ZLibDecoder(raw: true).convert(body);
    }
    at = start + size;
  }
  return null;
}

/// EPUB 的 dc:identifier（软件排版每次按制作计划重新生成，保持原格式则沿用原书）。
String _identifier(List<int> epub) {
  final container = utf8.decode(_zipEntry(epub, 'META-INF/container.xml')!);
  final opfPath = RegExp(r'full-path="([^"]+)"')
      .firstMatch(container)!
      .group(1)!;
  final opf = utf8.decode(_zipEntry(epub, opfPath)!);
  return RegExp(r'urn:sha256:[0-9a-f]{64}').firstMatch(opf)?.group(0) ?? '';
}

Future<ConversionOutput> _convert(
  PrototypeState state,
  String id,
  String directory,
  String format, {
  required bool original,
}) async {
  final session = LegacyConversionSession(state);
  try {
    final plan = await session.preview(
      ConversionRequest(
        books: [id],
        directory: directory,
        format: format,
        engine: format == 'EPUB'
            ? ''
            : Platform.environment[format == 'KFX'
                  ? 'EASYPUB_TEST_BOKAI'
                  : 'EASYPUB_TEST_KINDLING']!,
        generateCover: true,
        runChecks: false,
        keepOriginalEpub: original ? {id} : const {},
      ),
    );
    expect(
      plan.previewed,
      true,
      reason: plan.findings.map((f) => '${f.title}：${f.detail}').join('\n'),
    );
    if (original) {
      final note = plan.findings.singleWhere((f) => f.title == '保持原格式');
      expect(note.detail, contains('使用原 EPUB 的排版'));
    } else {
      expect(plan.findings.where((f) => f.title == '保持原格式'), isEmpty);
    }
    final result = (await session.commit(
      plan,
      acknowledgeWarnings: true,
    )).single;
    expect(result.complete, true, reason: result.detail);
    return result;
  } finally {
    session.dispose();
  }
}

/// V27：EPUB 两条转换路径——保持原格式 / 使用软件排版（OUT-079/080）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('修补说明文字', () {
    expect(
      passthroughSummary({
        'images': [{}, {}],
        'unreadable_images': [],
        'metadata': ['title', 'author'],
        'cover_added': true,
      }),
      '使用原 EPUB 的排版，不重排正文；原文件不变。\n为 Kindle 转换 2 张图片。\n'
      '按书籍信息写入：书名、作者。\n原 EPUB 没有封面，已加入本书封面。',
    );
  });

  testWidgets('从 EPUB 导入的书：保持原格式输出 EPUB / AZW3 / KFX，用的是原 EPUB；转换页逐本切换', (
    t,
  ) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String txtId, epubId;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v27-epub-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final txt = File('$root/样书.txt')
        ..writeAsStringSync('第一章 开始\n　　第一章正文。\n第二章 继续\n　　第二章正文。\n');
      await library.importFiles([txt.path]);
      txtId = state.currentId;
      // 用软件排版先做出一本 EPUB，再把它当原稿导入。
      Directory('$root/first').createSync();
      final first = await _convert(
        state,
        txtId,
        '$root/first',
        'EPUB',
        original: false,
      );
      final originalBytes = File(first.path).readAsBytesSync();
      final originalId = _identifier(originalBytes);
      expect(originalId, isNotEmpty);
      await library.importFiles([first.path]);
      epubId = state.currentId;
      expect(epubId, isNot(txtId));
      expect(
        library.books.value
            .singleWhere((b) => b.id == epubId)
            .format
            .toUpperCase(),
        'EPUB',
      );

      // 保持原格式：三种格式都完成；EPUB 成品沿用原 EPUB 的标识（没有重新生成）。
      for (final format in ['EPUB', 'AZW3', 'KFX']) {
        final dir = Directory('$root/original-$format')..createSync();
        final out = await _convert(
          state,
          epubId,
          dir.path,
          format,
          original: true,
        );
        expect(File(out.path).existsSync(), true);
        if (format == 'EPUB') {
          expect(_identifier(File(out.path).readAsBytesSync()), originalId);
        }
      }
      // 使用软件排版：重新生成，标识随制作计划变化。
      final dir = Directory('$root/layout')..createSync();
      final layout = await _convert(
        state,
        epubId,
        dir.path,
        'EPUB',
        original: false,
      );
      expect(
        _identifier(File(layout.path).readAsBytesSync()),
        isNot(originalId),
      );
      // 原 EPUB 不变。
      expect(File(first.path).readAsBytesSync(), originalBytes);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });

    // 转换页：只有 EPUB 书有路径切换图标；默认“使用软件排版”，点击切换。
    final draft = ConversionFormDraft();
    final session = library.openConversion();
    addTearDown(draft.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ConversionPage(
            library: library,
            picker: _NoPicker(),
            openRepair: (_, _) {},
            desktop: _Desktop(),
            session: session,
            draft: draft,
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    expect(find.byKey(ValueKey('conversion-epub-mode-$txtId')), findsNothing);
    final toggle = find.byKey(ValueKey('conversion-epub-mode-$epubId'));
    expect(toggle, findsOneWidget);
    expect(find.byTooltip(RegExp(r'^EPUB：使用软件排版')), findsOneWidget);
    await t.tap(toggle);
    await t.pump();
    expect(draft.epubOriginal[epubId], true);
    expect(find.byTooltip(RegExp(r'^EPUB：保持原格式')), findsOneWidget);
    expect(keepOriginalEpubFor(draft, library, [txtId, epubId]), {epubId});
    await t.pumpWidget(const SizedBox());
    session.dispose();
  });
}
