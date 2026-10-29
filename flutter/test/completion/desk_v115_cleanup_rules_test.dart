import 'dart:io';

import 'package:easypub_desktop/desk/cleanup/cleanup_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// V115：文本清理左侧规则栏——单击不再等双击判定；单击有变更的规则时切到“逐步骤差异”
/// 并停在这条规则的第一处；0.3 秒内连点同一行打开编辑。V116：变更列表滚到这一处。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('点规则立即选中并跳到它的变更，连点打开编辑', (t) async {
    t.view.physicalSize = const Size(1500, 950);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v115-rules-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final text = StringBuffer('第一章 开始\n');
      for (var i = 0; i < 30; i++) {
        text.writeln('　　第$i段正文，行尾有空格。   ');
        // 段间不空行，每三段多出三个空行（V116 起整段空行算一处）。
        if (i % 3 == 0) text.write('\n\n\n');
      }
      final file = File('$root/清理.txt')..writeAsStringSync('$text');
      await library.importFiles([file.path]);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle([bool Function()? done]) async {
      for (var i = 0; i < 300; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
        if (i >= 10 && (done == null || done())) return;
      }
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: CleanupPage(
            library: library,
            bookId: state.currentId,
            navigation: CleanupNavigationGuard(),
            onChecks: () {},
          ),
        ),
      ),
    );
    await settle();
    await t.tap(find.text('自动检测'));
    await settle(() => find.textContaining('处变更').evaluate().length >= 2);
    final second = find.text('合并连续空行').first;
    // 单击：同一帧里就选中，不等双击判定。
    await t.tap(second);
    await settle(() => find.textContaining('· 规则 2').evaluate().isNotEmpty);
    expect(find.textContaining('31 / 40 · 规则 2'), findsOneWidget);
    // 规则 2 的第一处排在规则 1 的 30 处之后，列表要滚下去才看得到。
    final list = t.widget<ListView>(
      find.byWidgetPredicate((w) => w is ListView && w.controller != null),
    );
    expect(list.controller!.offset, greaterThan(0));
    expect(find.text('采用此规则'), findsNothing);
    // 0.3 秒内连点同一行：打开编辑。
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(second);
    await t.pump(const Duration(milliseconds: 80));
    await t.tap(second);
    await settle(() => find.text('采用此规则').evaluate().isNotEmpty);
    expect(find.text('采用此规则'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
