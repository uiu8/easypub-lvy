import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/checks/issue_browser.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

/// 真实小说样本放在用户桌面，不随仓库提供；不在时如实跳过，不伪造输入。
final _novel =
    '${Platform.environment['USERPROFILE'] ?? ''}/Desktop/美漫斩杀线，但蜘蛛侠 - 除却君身三重雪.txt';

void main() {
  testWidgets(
    'real novel: issue details expose both chapter boundaries and actionable guidance',
    (t) async {
      t.view.physicalSize = const Size(980, 720);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late ChapterSession session;
      late ChapterIssuePage issues;
      final evidence = <String, Object?>{};
      await t.runAsync(() async {
        for (final font in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value)
                    .readAsBytes()
                    .then((b) => b.buffer.asByteData()),
              ))
              .load();
        }
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        await Directory('../artifacts/repair-chain-visual-20261008')
            .create(recursive: true);
        final root = await Directory(
          '../artifacts/repair-chain-visual-20261008',
        ).createTemp('profile-');
        state = PrototypeState(
          settingsDirectory: '${root.absolute.path}/settings',
        );
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        await library.importFiles([_novel]);
        session = library.openChapters(state.currentId);
        final tree = await session.read(0);
        issues = await session.issues(tree, 0, effective: true);
        final items = <Object>[];
        for (final i in issues.items) {
          final contexts = <Object>[];
          for (var a = 0; a < i.lines.length; a++) {
            final c = await (session as ChapterIssueContextSession)
                .issueContext(issues, i, anchor: a);
            contexts.add({
              'line': i.lines[a],
              'originalLine': c.originalLine,
              'effective': c.effectiveText,
              'original': c.originalText,
            });
          }
          items.add({
            'id': i.id,
            'category': i.category,
            'title': i.title,
            'evidence': i.evidence,
            'entryId': i.entryId,
            'nodeOffset': i.nodeOffset,
            'autoApplicable': i.autoApplicable,
            'contexts': contexts,
          });
        }
        evidence['items'] = items;
        final r = await session.repairs(tree);
        evidence['repair_count'] = r.total;
        evidence['repairs'] = r.changes
            .map((c) => {'id': c.id, 'title': c.title, 'line': c.line})
            .toList();
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final capture = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: deskTheme(),
            home: Scaffold(
              body: CheckIssueBrowser(
                session: session,
                enabled: true,
                onChapter: (_) {},
                onRepair: (_) {},
              ),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var n = 0; n < 250; n++) {
          await t.pump(const Duration(milliseconds: 20));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (n > 10 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
        }
      }

      await settle();
      final index = issues.items.indexWhere(
        (i) => i.title == '第161章后直接到了第163章',
      );
      expect(index, greaterThanOrEqualTo(0));
      t
          .widget<Slider>(find.byKey(const ValueKey('issue-position')))
          .onChangeEnd!(index.toDouble());
      await settle();
      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .toList();
      final selections = t
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .toList();
      evidence['visible_texts'] = [...texts, ...selections];
      evidence['shows_second_chapter_title'] = [
        ...texts,
        ...selections,
      ].any((s) => s.contains('美国翘臀拥有者'));
      evidence['has_local_repair_guidance'] = find
          .text('预览处理')
          .evaluate()
          .isNotEmpty;
      await t.runAsync(() async {
        File('../artifacts/repair-chain-visual-20261008/repro.json')
            .writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(evidence),
            );
      });
      await t.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final shot = await boundary.toImage(pixelRatio: 1);
        final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/repair-chain-visual-20261008/issue-detail.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        shot.dispose();
      });
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
      expect(
        evidence['shows_second_chapter_title'],
        true,
        reason: '用户需同时看见161章与163章的真实标题和断点；目前只展示第一处',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !File(_novel).existsSync(),
  );
}
