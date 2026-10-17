import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('local and catalog repairs use current draft, preserve source and reopen copies', () async {
    final root = (await Directory('../artifacts').createTemp('repair-chain-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final lib = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      lib.dispose();
      state.dispose();
    });
    await lib.load();
    await lib.savePatch({'check_after_import': false});
    Future<String> load(String name, String text) async {
      final file = File('$root/$name.txt')..writeAsStringSync(text);
      expect((await lib.importFiles([file.path])).single.succeeded, true);
      return state.currentId;
    }

    var id = await load(
      'recognition',
      '第41章 章名\n正文。\n第一节课在三楼的二年级混编班。\n正文。\n第42章 下一章\n正文。\n',
    );
    var session = lib.openChapters(id);
    var tree = await session.read(0);
    expect(tree.nodes.length, 2);
    expect((await session.issues(tree, 0, effective: true)).total, 0);
    // A legacy project must be repairable without silently replacing its old recipe.
    state.change(() => state.manuscript.structures.remove(id));
    tree = await session.read(0);
    expect(tree.nodes.length, 3);
    var options = await session.repairs(tree);
    final prose = options.changes.singleWhere(
      (c) => c.id.startsWith('prose-heading:'),
    );
    expect(prose.recommended, false);
    var plan = await session.previewRepairs(options, {prose.id});
    final copy = await (session as ChapterCopySession).exportCopy(
      plan.preview,
      '$root/local-copy.txt',
    );
    expect(
      File(copy.textPath).readAsStringSync(),
      File('$root/recognition.txt').readAsStringSync(),
    );
    expect(
      (await session.read(0)).nodes.length,
      3,
      reason: 'export must not apply to active draft',
    );
    await session.confirm(plan.preview);
    expect((await session.read(0)).nodes.length, 2);
    await session.undoConfirmed(plan.preview);
    expect((await session.read(0)).nodes.length, 3);
    expect((await lib.openProject(copy.projectPath)).succeeded, true);
    expect((await lib.openChapters(state.currentId).read(0)).nodes.length, 2);
    id = await load(
      'sections',
      '第41章 章名\n正文\n第一节 小节\n正文\n第二节 小节\n正文\n第42章 下章\n正文\n',
    );
    session = lib.openChapters(id);
    tree = await session.read(0);
    expect(tree.nodes.where((n) => n.role == 'section').length, 2);
    expect(
      (await session.issues(
        tree,
        0,
        effective: true,
      )).items.where((i) => i.category == 'number-reset'),
      isEmpty,
    );
    id = await load(
      'reset',
      '第一百零一章 前章\n正文\n第一章 新的开始\n正文\n第二章 延续\n正文\n第三章 新卷后续\n正文\n',
    );
    session = lib.openChapters(id);
    tree = await session.read(0);
    var report = await session.issues(tree, 0, effective: true);
    var issue = report.items.singleWhere((i) => i.category == 'number-reset');
    expect(issue.title, '第101章后出现了第1章');
    expect(issue.anchors.map((a) => a.title), ['第一百零一章 前章', '第一章 新的开始']);
    report = await session.reviewIssue(report, issue.id, 'confirmed_normal');
    expect(
      report.items.singleWhere((i) => i.id == issue.id).decision,
      'confirmed_normal',
    );
    expect(
      (await lib.saveProject('$root/review.easypub.json')).succeeded,
      true,
    );
    expect(
      (await lib.openProject('$root/review.easypub.json')).succeeded,
      true,
    );
    session = lib.openChapters(state.currentId);
    tree = await session.read(0);
    expect(
      (await session.issues(
        tree,
        0,
        effective: true,
      )).items.singleWhere((i) => i.category == 'number-reset').decision,
      'confirmed_normal',
    );
    options = await session.repairs(tree);
    plan = await session.previewRepairs(options, {
      options.changes.singleWhere((c) => c.id.startsWith('number-reset:')).id,
    });
    await session.confirm(plan.preview);
    expect(
      (await session.issues(
        await session.read(0),
        0,
        effective: true,
      )).items.where((i) => i.category == 'number-reset'),
      isEmpty,
    );
    id = await load('reviewed-duplicate', '第1章 开始\n第1章 开始\n正文\n第2章 结束\n尾声\n');
    session = lib.openChapters(id);
    tree = await session.read(0);
    report = await session.issues(tree, 0, effective: true);
    final duplicate = report.items.singleWhere(
      (i) => i.category == 'duplicate-title',
    );
    await session.reviewIssue(report, duplicate.id, 'confirmed_normal');
    expect(
      (await session.repairs(tree)).changes
          .singleWhere((c) => c.id == duplicate.id)
          .recommended,
      false,
    );
    const text = '第1章 开始\n甲文  \n2 中间\n乙文\n第3章 结束\n丙文\n';
    id = await load('catalog', text);
    session = lib.openChapters(id);
    tree = await session.read(0);
    final cleanup = lib.openCleanup(id);
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
    cleanup.dispose();
    tree = await session.read(0);
    await session.confirm(
      await session.preview(
        tree,
        RenameChapter(tree.nodes.first.id, '手工保留的标题'),
      ),
    );
    final catalog = lib.openCatalog(id);
    final snapshot = await catalog.acquire(
      'paste',
      '第一卷 上\n第1章 开始\n2 中间\n第二卷 下\n第3章 结束',
      declaredTotal: 3,
    );
    catalog.accept(snapshot);
    final alignment = await catalog.preview(snapshot, identityConfirmed: true);
    expect(alignment.matched, 3);
    expect(
      alignment.changes
          .where((c) => c.id.startsWith('catalog-heading:'))
          .length,
      1,
    );
    expect(
      alignment.changes
          .singleWhere((c) => c.id.startsWith('catalog-title:'))
          .recommended,
      false,
    );
    final draft = await catalog.prepareRepair(alignment);
    final preview = await draft.session.previewTree(draft.preview, 0);
    expect(preview.nodes.map((n) => n.title), [
      '第一卷 上',
      '手工保留的标题',
      '2 中间',
      '第二卷 下',
      '第3章 结束',
    ]);
    final receipt = await (draft.session as ChapterCopySession).exportCopy(
      draft.preview,
      '$root/catalog-copy.txt',
    );
    expect(
      File(receipt.textPath).readAsStringSync(),
      contains('手工保留的标题\n甲文\n'),
    );
    await draft.session.confirm(draft.preview);
    final again = await catalog.preview(snapshot, identityConfirmed: true);
    expect(
      again.changes.where((c) => c.recommended),
      isEmpty,
      reason: 'already created chapters and volumes must not reappear',
    );
    await draft.session.undoConfirmed(draft.preview);
    expect((await session.read(0)).nodes.map((n) => n.title), [
      '手工保留的标题',
      '第3章 结束',
    ]);
    expect(File('$root/catalog.txt').readAsStringSync(), text);
    expect((await lib.openProject(receipt.projectPath)).succeeded, true);
    expect(
      (await lib.openChapters(state.currentId).read(0)).nodes
          .map((n) => n.title),
      preview.nodes.map((n) => n.title),
    );
    File('$root/result.json').writeAsStringSync(
      jsonEncode({
        'passed': true,
        'local_copy': copy.projectPath,
        'catalog_copy': receipt.projectPath,
      }),
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
  test('real novel legacy repair removes prose headings and shows both gap anchors', () async {
    final sourcePath = Platform.environment['EASYPUB_REAL_BOOK'];
    if (sourcePath == null) return;
    final root = (await Directory('../artifacts').createTemp('repair-real-'))
        .absolute
        .path;
    final original = File(sourcePath).readAsBytesSync();
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final lib = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      lib.dispose();
      state.dispose();
    });
    await lib.load();
    await lib.savePatch({'check_after_import': false});
    await lib.importFiles([sourcePath]);
    final id = state.currentId;
    final s = lib.openChapters(id);
    var tree = await s.read(0);
    var report = await s.issues(tree, 0, effective: true);
    expect(report.items.where((i) => i.category == 'number-reset'), isEmpty);
    final gap = report.items.singleWhere((i) => i.category == 'number-gap');
    expect(gap.anchors.length, 2);
    expect(gap.anchors[0].title, contains('161'));
    expect(gap.anchors[1].title, contains('163'));
    final contexts = await Future.wait([
      for (var i = 0; i < 2; i++)
        (s as ChapterIssueContextSession).issueContext(report, gap, anchor: i),
    ]);
    expect(contexts[1].effectiveText, contains(gap.anchors[1].title));
    for (final anchor in gap.anchors) {
      final p = await s.read(anchor.nodeOffset);
      expect(p.nodes.any((n) => n.id == anchor.entryId), true);
      final body = await s.body(p, anchor.entryId, anchor.bodyOffset);
      expect(body.lines, isNotEmpty);
    }
    state.change(() => state.manuscript.structures.remove(id));
    tree = await s.read(0);
    final options = await s.repairs(tree);
    final fixes = options.changes
        .where((c) => c.id.startsWith('prose-heading:'))
        .toList();
    expect(fixes.length, 10);
    final plan = await s.previewRepairs(
      options,
      fixes.map((c) => c.id).toSet(),
    );
    await s.confirm(plan.preview);
    final outline = await (s as ChapterOutlineSession).readOutline();
    expect(
      outline.nodes.where(
        (n) =>
            n.title.contains('第一节课') ||
            n.title.contains('第一回尝试') ||
            n.title.contains('第二节课') ||
            n.title.contains('第三节课') ||
            n.title.contains('第三卷还差几页'),
      ),
      isEmpty,
    );
    report = await s.issues(await s.read(0), 0, effective: true);
    expect(
      report.items.where(
        (i) => i.category == 'number-reset' || i.category == 'prose-heading',
      ),
      isEmpty,
    );
    expect(File(sourcePath).readAsBytesSync(), original);
    File('$root/result.json').writeAsStringSync(
      jsonEncode({
        'passed': true,
        'fixed_prose_headings': fixes.length,
        'remaining': report.items
            .map((i) => {'title': i.title, 'category': i.category})
            .toList(),
        'anchors': gap.anchors
            .map(
              (a) => {
                'title': a.title,
                'line': a.line,
                'body_offset': a.bodyOffset,
              },
            )
            .toList(),
      }),
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
  test('catalog prerequisites repair missing headings and wrong volumes before reorder', () async {
    final root = (await Directory(
      '../artifacts',
    ).createTemp('repair-dependencies-')).absolute.path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final lib = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      lib.dispose();
      state.dispose();
    });
    await lib.load();
    await lib.savePatch({'check_after_import': false});
    for (final c in [
      (
        '第3章 结束\n丙文\n第1章 开始\n甲文\n第一节课在三楼。\n2 中间\n乙文\n',
        '第1章 开始\n2 中间\n第3章 结束',
        ['第1章 开始', '2 中间', '第3章 结束'],
      ),
      (
        '第一卷 上\n第1章 开始\n甲文\n第2章 中间\n乙文\n第二卷 下\n第3章 结束\n丙文\n',
        '第一卷 上\n第1章 开始\n第二卷 下\n第2章 中间\n第3章 结束',
        ['第一卷 上', '第1章 开始', '第二卷 下', '第2章 中间', '第3章 结束'],
      ),
    ].indexed) {
      final f = File('$root/book${c.$1}.txt')..writeAsStringSync(c.$2.$1);
      await lib.importFiles([f.path]);
      final id = state.currentId;
      state.change(() => state.manuscript.structures.remove(id));
      final catalog = lib.openCatalog(id);
      final ref = await catalog.acquire('paste', c.$2.$2, declaredTotal: 3);
      catalog.accept(ref);
      final alignment = await catalog.preview(
        ref,
        identityConfirmed: true,
        reorder: true,
      );
      expect(
        alignment.changes.any((v) => v.id == 'catalog-reorder'),
        true,
        reason: alignment.rows.map((r) => r.status).join(','),
      );
      final ids = alignment.changes
          .where(
            (v) =>
                v.id == 'catalog-reorder' ||
                v.id.startsWith('prose-heading:') ||
                v.id.startsWith('catalog-heading:'),
          )
          .map((v) => v.id)
          .toSet();
      final draft = await catalog.prepareRepair(alignment, selectedIds: ids);
      expect(
        (await draft.session.previewTree(
          draft.preview,
          0,
        )).nodes.map((n) => n.title),
        c.$2.$3,
      );
      await draft.session.confirm(draft.preview);
      expect(
        (await catalog.preview(
          ref,
          identityConfirmed: true,
          reorder: true,
        )).changes.where((v) => v.recommended),
        isEmpty,
      );
      expect(f.readAsStringSync(), c.$2.$1);
    }
  });
}
