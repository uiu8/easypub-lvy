import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';

void main() {
  test('screenshot manuscripts: numeric chapters and author notes', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('screenshot-books-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final evidence = <Object>[];
    try {
      await library.load();
      expect(await library.initializeWorkspace(), true);
      await library.savePatch({'check_after_import': false});
      for (final name in ['福尔摩斯小姐今天也怀疑我是凶手', '完蛋！我身边的问题少女有亿点多']) {
        final source = File(
          '${Platform.environment['EASYPUB_UI_SAMPLE_DIRECTORY']}/$name.txt',
        );
        final beforeHash = sha256.convert(source.readAsBytesSync()).toString();
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
        final session = library.openChapters(state.currentId);
        final before = await (session as ChapterOutlineSession).readOutline();
        final all = await session.repairs(await session.read(0));
        expect(
          all.changes.where(
            (c) => c.id.startsWith('number-reset:') && c.before.contains('加起来'),
          ),
          isEmpty,
        );
        final numeric = await (session as TargetedChapterRepairSession)
            .repairsForIssue(await session.read(0), 'unrecognized-heading:');
        final batches = <int>[];
        if (name.startsWith('福尔摩斯')) {
          expect(before.total, 1);
          expect(numeric.total, 429);
          var options = numeric;
          while (options.total > 0) {
            final plan = await session.previewRepairs(
              options,
              options.changes.map((c) => c.id).toSet(),
            );
            await session.confirm(plan.preview);
            batches.add(plan.changes.length);
            options = await (session as TargetedChapterRepairSession)
                .repairsForIssue(
                  await session.read(0),
                  'unrecognized-heading:',
                );
          }
          final after = await (session as ChapterOutlineSession).readOutline();
          expect(after.total, before.total + numeric.total);
          expect(
            after.nodes.any(
              (n) => n.title.contains('238') && n.title.contains('以命换伤'),
            ),
            true,
          );
        }
        evidence.add({
          'book': name,
          'before_nodes': before.total,
          'numeric_candidates': numeric.total,
          'applied_batches': batches,
          'after_nodes': (await session.read(0)).total,
          'original_sha256': beforeHash,
        });
        expect(sha256.convert(source.readAsBytesSync()).toString(), beforeHash);
      }
      expect(
        (await library.saveProject(
          '${root.path}/screenshot-books.easypub.json',
        )).succeeded,
        true,
      );
      expect(await library.flushWorkspace(), true);
      File(
        '${root.path}/evidence.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
