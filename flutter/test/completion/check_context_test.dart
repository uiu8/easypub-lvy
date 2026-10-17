import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';

void main() {
  test('issue anchors retain exact original context after cleanup and reject stale compositions', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('check-context-'))
        .absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    const original = '第一章 起\n正文\n\n\n第三章 终\n尾文\n';
    final source = File('${root.path}/源稿.txt')..writeAsStringSync(original);
    expect((await library.importFiles([source.path])).single.succeeded, true);
    final id = state.currentId;
    final cleanup = library.openCleanup(id);
    addTearDown(cleanup.dispose);
    await cleanup.apply(
      await cleanup.preview(
        jsonEncode({
          'kind': 'cleanup',
          'pipeline': [
            {'kind': 'collapse_blank_lines'},
          ],
        }),
      ),
    );
    final chapters = library.openChapters(id);
    final contexts = chapters as ChapterIssueContextSession;
    var tree = await chapters.read(0);
    final page = await chapters.issues(tree, 0, effective: true);
    final issue = page.items.firstWhere((i) => i.category == 'number-gap');
    expect(issue.lines, [1, 4]);
    expect(issue.originalLines, [1, 5]);
    final paired = await contexts.issueContext(page, issue, anchor: 1);
    expect(paired.originalLine, 5);
    expect(
      paired.rows.any(
        (row) => row.line == 4 && row.text == '第三章 终' && row.originalLine == 5,
      ),
      true,
    );
    expect(
      paired.originalRows.any((row) => row.line == 5 && row.text == '第三章 终'),
      true,
    );
    expect(paired.compositionId, isNotEmpty);
    expect(paired.originalText, contains('第三章 终'));
    await expectLater(
      contexts.issueContext(page, issue, anchor: 2),
      throwsFormatException,
    );
    await chapters.rename(tree, tree.nodes.last.id, '第五章 修订终');
    await expectLater(
      contexts.issueContext(page, issue, anchor: 1),
      throwsA(isA<FormatException>()),
    );
    tree = await chapters.read(0);
    final changed = await chapters.issues(tree, 0, effective: true);
    final changedIssue = changed.items.firstWhere(
      (i) => i.category == 'number-gap',
    );
    final after = await contexts.issueContext(changed, changedIssue, anchor: 1);
    expect(after.originalLine, 5);
    expect(after.effectiveText, contains('第五章 修订终'));
    expect(after.originalText, contains('第三章 终'));
    expect(after.originalText, isNot(contains('第五章 修订终')));
    final raw = await chapters.issues(tree, 0);
    final rawContext = await contexts.issueContext(
      raw,
      raw.items.first,
      anchor: 1,
    );
    expect(rawContext.effectiveText, isNull);
    expect(rawContext.originalLine, 5);
    expect(source.readAsStringSync(), original);
  });
}
