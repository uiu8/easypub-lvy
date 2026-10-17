import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_book_check_session.dart';
import 'package:easypub_desktop/infrastructure/check_report_cache.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/application/cleanup_rule_resolution.dart';
import 'package:easypub_desktop/application/conversion_snapshot.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/settings_page.dart';

/// V19：检查报告版本号（CHK-060）、缓存回收（CHK-061/SET-065）、
/// 书库刷新按稿件版本缓存（LIB-114）。真实 Rust。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  Future<(PrototypeState, LegacyLibraryAdapter, String, List<String>)> open(
    String prefix, {
    int books = 2,
  }) async {
    final root = (await Directory('../artifacts').createTemp(prefix))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    await library.load();
    await library.savePatch({'check_after_import': false});
    final ids = <String>[];
    for (var i = 0; i < books; i++) {
      final file = File('$root/书$i.txt')
        ..writeAsStringSync('第一章 开始\n正文$i\n第二章 后续\n后文\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      ids.add(state.currentId);
    }
    return (state, library, root, ids);
  }

  Future<void> author(LegacyLibraryAdapter library, String id, String v) async {
    final info = library.openBookInformation(id);
    try {
      await info.apply(await info.preview({'author': v}));
    } finally {
      info.dispose();
    }
  }

  Future<BookCheckReport> check(LegacyLibraryAdapter library, String id) async {
    final checks = library.openChecks(id);
    try {
      return await checks.inspect();
    } finally {
      checks.dispose();
    }
  }

  test('报告版本号：新报告写入版本与书的标识；无版本号的旧报告只按 V14 规则归类一次（CHK-060）', () async {
    final (state, library, root, ids) = await open('v19-schema-', books: 1);
    try {
      final id = ids.single;
      final report = await check(library, id);
      expect(report.schema, checkReportSchema);
      expect(report.bookId, id);
      final file = LegacyBookCheckSession.cacheFile(state, report.guard)!;
      final saved = jsonDecode(file.readAsStringSync()) as Map;
      expect(saved['schema'], checkReportSchema);
      expect(saved['book_id'], id);
      expect(BookCheckReport.fromJson(saved).outdated, false);
      // V12–V18 写入的报告（有检查时间、清理已结构化）：归为 1，不需要重新检查。
      final unversioned = Map.of(saved)
        ..remove('schema')
        ..remove('book_id');
      expect(BookCheckReport.fromJson(unversioned).schema, 1);
      // V12 前的报告（没有检查时间）：归为 0，需要重新检查。
      final legacy = Map.of(unversioned)..remove('checked_at');
      expect(BookCheckReport.fromJson(legacy).outdated, true);
      expect(
        LegacyBookCheckSession.summaryFor(state, id).status,
        isNot('检查已过期'),
      );
      // 磁盘上换成旧报告、内存里没有时：书库显示“检查已过期”，不给数量。
      final reopened = PrototypeState(settingsDirectory: '$root/settings');
      final again = LegacyLibraryAdapter(backend: reopened);
      try {
        await again.load();
        expect(
          (await library.saveProject('$root/v19.easypub.json')).succeeded,
          true,
        );
        // 先换成旧报告再打开项目：打开时书库刷新就会读到它。
        file.writeAsStringSync(jsonEncode(legacy));
        expect(
          (await again.openProject('$root/v19.easypub.json')).succeeded,
          true,
        );
        final summary = LegacyBookCheckSession.summaryFor(reopened, id);
        expect(summary.status, '检查已过期');
        expect(summary.pending, isNull);
      } finally {
        again.dispose();
        reopened.dispose();
      }
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('书库刷新按稿件版本缓存检查指纹：任何输入变化都会得到新的指纹（LIB-114）', () async {
    final (state, library, _, ids) = await open('v19-guard-');
    try {
      // 与缓存前的算法逐项相同的参照值。
      String reference(String id) => publicationFingerprint({
        'check': [
          state.shelf.books.firstWhere((b) => b.id == id).source?.sourceId,
          state.production.settings(id),
          state.manuscript.effectiveBase(id),
          state.manuscript.effectiveSelection(id),
          resolveCleanupRules(
            state.globalConfiguration,
            bookDraft: state.cleanup.drafts[id],
          ).fingerprint,
        ],
      });
      void same() {
        for (final id in ids) {
          expect(LegacyBookCheckSession.contextFor(state, id), reference(id));
          expect(
            LegacyBookCheckSession.contextFor(
              state,
              id,
              version: state.publicationContext(id),
            ),
            reference(id),
          );
        }
      }

      same();
      final before = LegacyBookCheckSession.contextFor(state, ids[0]);
      // 制作设置（书籍信息）变化。
      await author(library, ids[0], '新作者');
      same();
      final afterAuthor = LegacyBookCheckSession.contextFor(state, ids[0]);
      expect(afterAuthor, isNot(before));
      // 本书清理设置变化。
      final cleanup = library.openCleanup(ids[0]);
      try {
        await cleanup.apply(
          await cleanup.preview(
            jsonEncode({
              'kind': 'cleanup',
              'pipeline': [
                {'kind': 'trim_trailing_spaces'},
              ],
            }),
          ),
        );
      } finally {
        cleanup.dispose();
      }
      same();
      final afterCleanup = LegacyBookCheckSession.contextFor(state, ids[0]);
      expect(afterCleanup, isNot(afterAuthor));
      // 章节修改。
      final chapters = library.openChapters(ids[0]);
      final page = await chapters.read(0);
      await chapters.rename(page, page.nodes.first.id, '第一章 改名');
      same();
      expect(
        LegacyBookCheckSession.contextFor(state, ids[0]),
        isNot(afterCleanup),
      );

      // 还没有检查过时书库没有状态；检查后立即能查到，不被“没有文件”的缓存挡住。
      expect(LegacyBookCheckSession.summaryFor(state, ids[1]).status, isNull);
      await check(library, ids[1]);
      expect(
        LegacyBookCheckSession.summaryFor(state, ids[1]).status,
        isNotNull,
      );
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  test('检查缓存回收：保留当前稿与上一稿，先统计再删，删前核对文件未变（CHK-061）', () async {
    final (state, library, root, ids) = await open('v19-cache-', books: 1);
    try {
      final id = ids.single;
      final directory = Directory('$root/settings/check-reports');
      final first = await check(library, id);
      await author(library, id, '甲');
      final second = await check(library, id);
      await author(library, id, '乙');
      final third = await check(library, id);
      File name(BookCheckReport r) =>
          LegacyBookCheckSession.cacheFile(state, r.guard)!;
      // 无法归属的旧报告（V19 前，没有书的标识）。
      final legacy =
          File('${directory.path}/${checkReportFileName('legacy-guard')}')
            ..writeAsStringSync(
              jsonEncode({'guard': 'legacy-guard', 'domains': []}),
            );
      // 其他项目中的书：保留最近两份。
      final other = [
        for (var i = 0; i < 3; i++)
          File('${directory.path}/${checkReportFileName('other-$i')}')
            ..writeAsStringSync(
              jsonEncode({
                'schema': 1,
                'book_id': 'd:/其他项目/书.txt',
                'guard': 'other-$i',
                'checked_at': DateTime(2026, 10, 1 + i).toIso8601String(),
                'domains': [],
              }),
            ),
      ];
      // 不是缓存文件名的文件不在统计范围内。
      final note = File('${directory.path}/说明.txt')..writeAsStringSync('x');

      final preview = await library.previewCheckCacheCleanup();
      expect(preview.total, 7);
      expect(preview.unattributed, 1);
      expect(preview.older, 2);
      expect(preview.kept, 4);
      expect(preview.removable, 3);
      expect(
        preview.files.map((f) => File(f.path).uri.pathSegments.last).toSet(),
        {
          name(first).uri.pathSegments.last,
          legacy.uri.pathSegments.last,
          other[0].uri.pathSegments.last,
        },
      );
      expect(preview.lastCleanup, isNull);
      // 统计之后才改动的文件不删。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      legacy.writeAsStringSync(jsonEncode({'guard': 'legacy-guard'}));

      final result = await library.cleanCheckCache(preview);
      expect(result.deleted, 2);
      expect(result.skipped, 1);
      expect(name(first).existsSync(), false);
      expect(other[0].existsSync(), false);
      for (final kept in [name(second), name(third), other[1], other[2]]) {
        expect(kept.existsSync(), true, reason: kept.path);
      }
      expect(legacy.existsSync(), true);
      expect(note.existsSync(), true);
      // 原稿未动；当前稿的报告仍可用。
      expect(File('$root/书0.txt').readAsStringSync(), contains('正文0'));
      expect(LegacyBookCheckSession.summaryFor(state, id).status, isNotNull);
      final again = await library.previewCheckCacheCleanup();
      expect(again.lastCleanup?.deleted, 2);
      expect(again.removable, 1);
    } finally {
      library.dispose();
      state.dispose();
    }
  });

  testWidgets('设置“数据与迁移”：检查缓存统计，确认后才清理（SET-065）', (t) async {
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String root;
    await t.runAsync(() async {
      final opened = await open('v19-settings-', books: 1);
      (state, library, root) = (opened.$1, opened.$2, opened.$3);
      await check(library, opened.$4.single);
      File(
        '$root/settings/check-reports/${checkReportFileName('legacy-guard')}',
      ).writeAsStringSync(jsonEncode({'guard': 'legacy-guard'}));
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 200; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
      }
      fail('settings still busy');
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: SettingsPage(settings: library, library: library),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('数据与迁移').first);
    await until(() => find.textContaining('2 份 ·').evaluate().isNotEmpty);
    await t.pumpAndSettle();
    expect(find.text('检查缓存'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-check-cache-total')),
        matching: find.textContaining('2 份'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-check-cache-removable')),
        matching: find.textContaining('1 份'),
      ),
      findsOneWidget,
    );
    expect(find.text('还没有清理过'), findsOneWidget);
    await t.ensureVisible(
      find.byKey(const ValueKey('settings-check-cache-clean')),
    );
    await t.tap(find.byKey(const ValueKey('settings-check-cache-clean')));
    await t.pumpAndSettle();
    expect(find.text('清理检查缓存？'), findsOneWidget);
    expect(find.textContaining('旧版本、无法归属到书的 1 份'), findsOneWidget);
    // 取消：什么都不删。
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(
      Directory('$root/settings/check-reports')
          .listSync()
          .whereType<File>()
          .length,
      2,
    );
    await t.tap(find.byKey(const ValueKey('settings-check-cache-clean')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('settings-check-cache-confirm')));
    await until(() => find.textContaining('已删除 1 份检查缓存').evaluate().isNotEmpty);
    await until(
      () => find
          .descendant(
            of: find.byKey(const ValueKey('settings-check-cache-last')),
            matching: find.textContaining('1 份'),
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
