import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// 注释样书（文字为本工具自拟）：两章，含 ①、[2]、〔3〕 三条成对注释和一个不成对的 ④。
const sample =
    '第一章 雾港\n'
    '　　港口的雾①从傍晚开始往岸上爬，先是吞掉了灯塔的底座。\n'
    '　　老周把船缆绕在桩上[2]，抬头看了一眼天色。\n'
    '　　这里没有对应注释的标记④应原样保留。\n'
    '①雾：近地面空气中的水汽凝结成的小水滴。\n'
    '[2] 桩：码头边用来系船的铁柱或木柱。\n'
    '第二章 旧码头\n'
    '　　天亮的时候，雾散了，旧码头〔3〕露出了它斑驳的样子。\n'
    '〔3〕旧码头：清末修建，后来废弃。\n';

/// 生成 Kindle 真机注释样书：`tools/test_flutter.ps1 -TestPaths tool/kindle_notes_sample_test.dart`。
void main() {
  test('生成弹出注释样书（KFX、AZW3、EPUB）', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final out = Directory('../artifacts/kindle-notes-sample-20261015');
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
    final work = (await Directory('../artifacts').createTemp('kindle-notes-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$work/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      expect(await library.savePatch({'check_after_import': false}), true);
      final source = File('$work/注释样书.txt')..writeAsStringSync(sample);
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      final change = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'note_style': {'op': 'set', 'value': 'popup'},
          },
        },
      });
      expect(await state.production.confirm(change), true);
      for (final format in ['EPUB', 'AZW3', 'KFX']) {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: out.absolute.path,
              format: format,
              engine: switch (format) {
                'KFX' => Platform.environment['EASYPUB_TEST_BOKAI']!,
                'AZW3' => Platform.environment['EASYPUB_TEST_KINDLING']!,
                _ => '',
              },
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true);
          final result = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(result.complete, true, reason: '$format ${result.detail}');
        } finally {
          session.dispose();
        }
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
