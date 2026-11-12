import 'dart:io';

import 'package:easypub_desktop/application/cleanup_service.dart';
import 'package:easypub_desktop/desk/cleanup/cleanup_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 文本清理默认列出全部内置规则，每条一个开关，显示在本书里会改几处。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('内置规则清单：试算改动数，开关加入或停用，简繁只开一个', (t) async {
    t.view.physicalSize = const Size(1500, 950);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v134-builtin-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final text = StringBuffer('第一章 開始\n');
      for (var i = 0; i < 6; i++) {
        text.writeln('　　第$i段正文，這裡有繁體字。   ');
      }
      final file = File('$root/清理.txt')..writeAsStringSync('$text');
      await library.importFiles([file.path]);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> settle([bool Function()? done]) async {
      for (var i = 0; i < 400; i++) {
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
    Finder row(String id) => find.byKey(ValueKey('cleanup-builtin-$id'));
    String rowText(String id) => t
        .widgetList<Text>(
          find.descendant(of: row(id), matching: find.byType(Text)),
        )
        .map((w) => w.data ?? '')
        .join('|');
    // 清单比一屏长：简繁两条在下面，要滚过去才看得到。
    Future<void> scrollList(double dy) async {
      await t.drag(
        find.byKey(const ValueKey('cleanup-builtin-rules')),
        Offset(0, dy),
      );
      await t.pump();
    }

    // 试算完：行尾空白 6 处，繁体转简体有改动。
    await settle(() => rowText('trim').contains('6 处'));
    expect(rowText('trim'), contains('6 处'));
    // 网文下载残留的四条排在“常用”后面。
    for (final id in ['promo', 'tail', 'authornotes', 'paging']) {
      expect(row(id), findsOneWidget);
    }
    await scrollList(-600);
    await settle(
      () => rowText('s2t').isNotEmpty && !rowText('s2t').contains('计算中'),
    );
    expect(rowText('t2s'), contains('处'));
    expect(rowText('s2t'), isNot(contains('计算中')));
    Switch toggle(String id) => t.widget<Switch>(
      find.descendant(of: row(id), matching: find.byType(Switch)),
    );
    expect(toggle('t2s').value, false);

    await t.tap(row('t2s'));
    await settle();
    expect(toggle('t2s').value, true);
    await t.tap(row('s2t'));
    await settle();
    expect(toggle('s2t').value, true);
    expect(toggle('t2s').value, false);
    await scrollList(600);
    expect(toggle('trim').value, true);
    await t.tap(row('trim'));
    await settle();
    expect(toggle('trim').value, false);

    // 执行顺序页里能看到加进去的两条简繁规则，停用的仍保留设置。
    await t.tap(find.text('执行顺序'));
    await settle();
    expect(find.text('繁体转简体'), findsOneWidget);
    expect(find.text('简体转繁体'), findsOneWidget);
    expect(cleanupLabels['chinese_variant'], '简繁转换');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
