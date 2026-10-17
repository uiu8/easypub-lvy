import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';

/// 六卷矩阵用例（原 six_volume_current_matrix_test.dart）。V21 起拆成 4 个测试文件
/// 并行运行，各跑一部分场景；用例内容与名称不变。
void sixVolumeMatrix(List<String> scenarios) {
  setUpAll(
    () => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  for (final scenario in scenarios) {
    for (var mode = 1; mode <= 4; mode++) {
      test(
        '$scenario M$mode current repair, copy/reopen and EPUB/Kindling',
        () async {
          final root = Directory(
            '${Platform.environment['EASYPUB_MATRIX_ROOT']}/$scenario-M$mode',
          )..createSync(recursive: true);
          final fixture = Directory(
            scenario == 'MIX'
                ? '../samples/六卷690章修复验收'
                : '../samples/章节独立场景/$scenario',
          ).absolute;
          final source = File('${fixture.path}/缺陷样书.txt');
          final original = source.readAsBytesSync();
          final truth = jsonDecode(
            File('${fixture.path}/真值清单.json').readAsStringSync(),
          ) as Map;
          final state = PrototypeState(
            settingsDirectory: '${root.path}/settings',
          );
          final lib = LegacyLibraryAdapter(backend: state);
          addTearDown(() {
            lib.dispose();
            state.dispose();
          });
          await lib.load();
          await lib.savePatch({'check_after_import': false});
          expect((await lib.importFiles([source.path])).single.succeeded, true);
          final id = state.currentId;
          var s = lib.openChapters(id);
          List<Object> outline(ChapterPage p) => [
            for (final n in p.nodes) [n.title, n.role, n.depth, n.inToc],
          ];
          Future<ChapterPage> tree() =>
              (s as ChapterOutlineSession).readOutline();
          final before = outline(await tree());
          final local = await s.repairs(await s.read(0));
          final duplicateLines = {
            for (final i in (truth['instances'] as List).cast<Map>())
              if (i['duplicate'] == true) i['start_line'] as int,
          };
          bool select(ChapterRepairChange c) =>
              c.recommended ||
              (c.id.startsWith('duplicate-content:') &&
                  duplicateLines.contains(c.line)) ||
              c.id.startsWith('missing-heading-prefix:') ||
              c.id.startsWith('unrecognized-heading:') ||
              c.id.startsWith('heading-number-typo:') ||
              (scenario == 'S1' && c.id.startsWith('number-reset:'));
          ChapterEditPreview preview;
          List<ChapterRepairChange> chosen;
          final facts = <String, Object?>{};
          if (mode == 2 || mode == 4) {
            final catalog = lib.openCatalog(id);
            final ref = await catalog.acquire(
              'paste',
              File('${fixture.path}/参考目录.txt').readAsStringSync(),
              declaredTotal: 690,
            );
            catalog.accept(ref);
            final alignment = await catalog.preview(
              ref,
              identityConfirmed: true,
              reorder: true,
            );
            final ids = alignment.changes
                .where(
                  (c) =>
                      select(c) ||
                      c.id.startsWith('catalog-title:') ||
                      c.id.startsWith('catalog-heading:') ||
                      c.id == 'catalog-reorder',
                )
                .map((c) => c.id)
                .toSet();
            for (final c
                in alignment.changes
                    .where((c) => ids.contains(c.id))
                    .toList()) {
              ids.addAll(c.requires);
            }
            chosen = alignment.changes
                .where((c) => ids.contains(c.id))
                .toList();
            final draft = await catalog.prepareRepair(
              alignment,
              selectedIds: ids,
            );
            s = draft.session;
            preview = draft.preview;
            facts.addAll({
              'matched': alignment.matched,
              'unresolved': alignment.unresolved,
              'alignment': [
                for (final r in alignment.rows.where(
                  (r) => r.status != 'matched',
                ))
                  {'title': r.referenceTitle, 'status': r.status},
              ],
            });
          } else {
            chosen = local.changes.where(select).toList();
            preview = chosen.isEmpty
                ? await (s as ChapterCopySession).previewCurrentCopy(
                    await s.read(0),
                  )
                : (await s.previewRepairs(
                    local,
                    chosen.map((c) => c.id).toSet(),
                  )).preview;
          }
          expect(
            outline(await tree()),
            before,
            reason: 'preview must not mutate current manuscript',
          );
          facts['selected'] = [
            for (final c in chosen)
              {
                'id': c.id,
                'line': c.line,
                'before': c.before,
                'after': c.after,
              },
          ];
          if (mode >= 3) {
            final copy = await (s as ChapterCopySession).exportCopy(
              preview,
              '${root.path}/修订书稿.txt',
            );
            expect(
              outline(await tree()),
              before,
              reason: 'saving a copy must not apply to current manuscript',
            );
            facts['copy'] = copy.textPath;
            expect((await lib.openProject(copy.projectPath)).succeeded, true);
            s = lib.openChapters(state.currentId);
          } else if (chosen.isNotEmpty) {
            await s.confirm(preview);
            final after = outline(await tree());
            await s.undoConfirmed(preview);
            expect(outline(await tree()), before);
            await s.history(await s.read(0), undo: false);
            expect(outline(await tree()), after);
          }
          final after = outline(await tree());
          final project = '${root.path}/saved.easypub.json';
          expect((await lib.saveProject(project)).succeeded, true);
          expect((await lib.openProject(project)).succeeded, true);
          s = lib.openChapters(state.currentId);
          expect(outline(await tree()), after);
          final issues = await s.issues(await s.read(0), 0, effective: true);
          facts['remaining'] = {
            'total': issues.total,
            'items': [
              for (final i in issues.items)
                {'type': i.category, 'title': i.title},
            ],
          };
          final outputs = <Object>[];
          for (final format in ['EPUB', 'AZW3']) {
            final convert = LegacyConversionSession(state);
            try {
              final plan = await convert.preview(
                ConversionRequest(
                  books: [state.currentId],
                  directory: root.path,
                  format: format,
                  engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
                  generateCover: true,
                  runChecks: false,
                ),
              );
              expect(
                plan.previewed,
                true,
                reason: plan.findings.map((f) => f.detail).join('\n'),
              );
              final result = (await convert.commit(
                plan,
                acknowledgeWarnings: true,
              )).single;
              expect(result.complete, true, reason: result.detail);
              outputs.add({'format': format, 'path': result.path});
            } finally {
              convert.dispose();
            }
          }
          expect(source.readAsBytesSync(), original);
          File('${root.path}/evidence.json').writeAsStringSync(
            jsonEncode({
              'scenario': scenario,
              'mode': mode,
              'fixture': fixture.path,
              'source_unchanged': true,
              'preview_unchanged': true,
              'project_reopened': true,
              'outline': after,
              'outputs': outputs,
              ...facts,
            }),
          );
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }
  }
}
