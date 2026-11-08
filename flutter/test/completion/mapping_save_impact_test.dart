import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('save impact preserves books, reports unreadable sources and rejects stale confirmation', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('mapping-save-impact-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final first = File('${root.path}/first.txt')
        ..writeAsStringSync('第一章 开始\n第一本正文。\n');
      final second = File('${root.path}/second.txt')
        ..writeAsStringSync('第一章 开始\n第二本正文。\n');
      await library.importFiles([first.path]);
      final id = state.currentId;
      await library.importFiles([second.path]);
      final other = state.currentId;
      final info = library.openBookInformation(other);
      await info.apply(await info.preview({'author': '手工作者'}));
      info.dispose();
      final session = library.openMapping();
      final review = session as MappingSaveReviewSession;
      final rules = [
        MappingRule(root.path, {
          'author': {'op': 'set', 'value': '规则作者'},
        }),
      ];
      final before = state.production.settings(id);
      final impact = await review.previewRuleSave(rules);
      expect(impact.items.length, 2);
      expect(impact.changedBooks, 1);
      expect(impact.uncheckedBooks, 0);
      expect(state.globalFolderRules, isEmpty);
      expect(state.production.settings(id), before);
      await review.saveReviewedRules(impact);
      expect(
        state.globalFolderRules.single['fields']['author']['value'],
        '规则作者',
      );
      expect(state.production.settings(id), before);
      expect(state.production.settings(other)['author'], '手工作者');
      await expectLater(
        review.saveReviewedRules(impact),
        throwsFormatException,
      );
      final pending = await review.previewRuleSave(rules);
      final edit = library.openBookInformation(id);
      await edit.apply(await edit.preview({'title': '修改书名'}));
      edit.dispose();
      await expectLater(
        review.saveReviewedRules(pending),
        throwsFormatException,
      );
      final older = await review.previewRuleSave(rules);
      await review.previewRuleSave(rules);
      await expectLater(review.saveReviewedRules(older), throwsFormatException);
      first.renameSync('${first.path}.moved');
      final partial = await review.previewRuleSave(rules);
      expect(partial.uncheckedBooks, 1);
      expect(partial.items.length, 2);
      expect(
        partial.items.firstWhere((item) => item.bookId == id).error,
        isNotEmpty,
      );
      await review.saveReviewedRules(partial);
      expect(state.production.settings(other)['author'], '手工作者');
      final project = library.openMapping();
      final scoped = project as ProjectMappingSession;
      scoped.selectProjectScope(true);
      final projectReview = project as MappingSaveReviewSession;
      final proposed = await projectReview.previewRuleSave([
        MappingRule(root.path, {
          'publisher': {'op': 'set', 'value': '项目出版社'},
        }),
      ]);
      expect(
        scoped.projectEnabled,
        false,
        reason: 'impact must not toggle project configuration',
      );
      expect(
        proposed.items
            .firstWhere((item) => item.bookId == other)
            .diff!
            .after['publisher'],
        '项目出版社',
      );
      await projectReview.saveReviewedRules(proposed);
      expect(scoped.projectEnabled, true);
      expect(state.production.settings(other)['publisher'], '');
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
