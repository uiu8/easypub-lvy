import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/cleanup_rule_resolution.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('rule resolution distinguishes inheritance and empty overrides and isolates editable snapshots', () {
    expect(resolveCleanupRules({}).pipeline, defaultCleanupPipeline);
    final global = {
      'automatic_cleanup_pipeline': [
        {
          'kind': 'configured',
          'enabled': false,
          'scope': 'body',
          'rule': {'kind': 'trim_trailing_spaces'},
        },
      ],
    };
    final resolved = resolveCleanupRules(global);
    expect(resolved.origin, 'global');
    expect(resolved.enabled, false);
    (resolved.pipeline.single['rule'] as Map)['kind'] = 'collapse_blank_lines';
    expect(
      (resolveCleanupRules(global).pipeline.single['rule'] as Map)['kind'],
      'trim_trailing_spaces',
    );
    expect(
      resolveCleanupRules(
        global,
        bookDraft: {
          'pipeline': [],
          'rules': ['remove_ad_lines'],
        },
      ).pipeline,
      isEmpty,
    );
    expect(
      resolveCleanupRules(global, bookDraft: {'pipeline': null}).origin,
      'global',
    );
    expect(
      resolveCleanupRules({
        'automatic_cleanup_pipeline': null,
        'automatic_cleanup_rules': [],
      }).enabled,
      false,
    );
    expect(
      resolveCleanupRules(
        {},
        bookDraft: {
          'rules': ['collapse_blank_lines', 'trim_trailing_spaces'],
        },
      ).pipeline,
      [
        {'kind': 'trim_trailing_spaces'},
        {'kind': 'collapse_blank_lines'},
      ],
    );
  });
  test('real import check cleanup and global/book overrides share semantics across save reopen', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('cleanup-resolution-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    const original = '第一章 开始\n正文尾空格  \n\n\n广告：示例\n第二章 后续\n正文结束。\n';
    final source = File('${root.path}/source.txt')..writeAsStringSync(original);
    final other = File('${root.path}/other.txt')..writeAsStringSync(original);
    final imported = await library.importFiles([source.path, other.path]);
    expect(imported.every((r) => r.succeeded), true);
    final id = library.books.value.first.id,
        otherId = library.books.value.last.id;
    var cleanup = library.openCleanup(id);
    addTearDown(() => cleanup.dispose());
    final checks = library.openChecks(id);
    addTearDown(checks.dispose);
    final otherChecks = library.openChecks(otherId);
    addTearDown(otherChecks.dispose);
    final importedReport = (checks as CachedBookCheckSession).latest;
    expect(importedReport, isNotNull);
    expect(jsonDecode(cleanup.settings)['pipeline'], defaultCleanupPipeline);
    final preview = await cleanup.preview(cleanup.settings);
    final diagnostic = await cleanup.recheck();
    expect(diagnostic.changes, preview.total);
    expect(diagnostic.candidates, preview.candidateTotal);
    expect(diagnostic.candidates, 1);
    expect(
      importedReport!.domains.singleWhere((d) => d.id == 'cleanup').status,
      contains('1 条广告候选'),
    );
    expect(source.readAsStringSync(), original);
    expect(await library.savePatch({'automatic_cleanup_pipeline': []}), true);
    expect(checks.isCurrent(importedReport), false);
    expect(jsonDecode(cleanup.settings)['pipeline'], isEmpty);
    expect((await cleanup.recheck()).changes, 0);
    expect(
      (await checks.inspect()).domains
          .singleWhere((d) => d.id == 'cleanup')
          .status,
      '未启用',
    );
    // Adopt an explicit book rule while global rules are disabled.
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
    final own = await checks.inspect();
    expect(
      own.domains.singleWhere((d) => d.id == 'cleanup').status,
      isNot('未启用'),
    );
    expect((await cleanup.recheck()).candidates, 0);
    final ownInspection = await cleanup.recheck();
    final otherReport = await otherChecks.inspect();
    expect(
      await library.savePatch({
        'automatic_cleanup_pipeline': [
          {'kind': 'remove_ad_lines'},
        ],
      }),
      true,
    );
    expect(
      checks.isCurrent(own),
      true,
      reason: 'global rule edits do not invalidate explicit book rules',
    );
    expect(otherChecks.isCurrent(otherReport), false);
    expect(cleanup.isInspectionCurrent(ownInspection), true);
    expect(jsonDecode(cleanup.settings)['pipeline'], [
      {'kind': 'trim_trailing_spaces'},
    ]);
    final inherited = library.openCleanup(otherId);
    expect((await inherited.recheck()).candidates, 1);
    inherited.dispose();
    // An explicit empty book pipeline remains empty after saving/reopening.
    await cleanup.apply(
      await cleanup.preview(jsonEncode({'kind': 'cleanup', 'pipeline': []})),
    );
    expect(
      (await checks.inspect()).domains
          .singleWhere((d) => d.id == 'cleanup')
          .status,
      '未启用',
    );
    final project = '${root.path}/rules.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    cleanup.dispose();
    expect((await library.openProject(project)).succeeded, true);
    cleanup = library.openCleanup(id);
    expect(jsonDecode(cleanup.settings)['pipeline'], isEmpty);
    expect((await cleanup.recheck()).candidates, 0);
    expect(source.readAsStringSync(), original);
    expect(other.readAsStringSync(), original);
    File('${root.path}/evidence.json').writeAsStringSync(
      jsonEncode({
        'defaultRules': 3,
        'importAndCleanupAgree': true,
        'explicitEmptyPreserved': true,
        'bookOverrideUnaffectedByGlobal': true,
        'sourcesUnchanged': true,
        'project': project,
      }),
    );
  });
}
