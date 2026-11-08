import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'legacy_state_helpers.dart';

void main() {
  testWidgets('mixed batch prepares all domains before one publication', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      final root = Directory('../artifacts/frontend-rewrite/book-batch');
      await root.create(recursive: true);
      final backend = PrototypeState(
        settingsDirectory: '${root.absolute.path}/settings',
      );
      final library = LegacyLibraryAdapter(backend: backend);
      final ids = <String>[];
      const original = '第一章 来信\n河边来了信。   \n第二章 夜渡\n天色晚了。   \n';
      try {
        for (final name in ['甲', '乙']) {
          final file = File('${root.path}/$name.txt');
          await file.writeAsString(original);
          await backend.importBookOutcome(file.absolute.path);
          ids.add(backend.currentId);
        }
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.green, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(4, 4);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        picture.dispose();
        final cover = File('${root.path}/cover.png').absolute;
        await cover.writeAsBytes(bytes);
        final info = library.openBookInformation(ids.first);
        await info.apply(
          await info.preview({'author': '批量作者', 'cover_path': cover.path}),
        );
        info.dispose();
        final layout = library.openLayout(ids.first);
        await layout.apply(
          await layout.preview({'font_size': 25.0, 'font_size_unit': 'px'}),
        );
        layout.dispose();
        final cleanup = library.openCleanup(ids.first);
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
        final oldCover = backend.draftFor(ids.last).coverPath;
        backend.draftFor(ids.last).coverPath =
            '${root.absolute.path}/missing.png';
        final diagnostic = library.openBookBatch(ids.first);
        final invalidBefore = jsonEncode([
          backend.production.settings(ids.first),
          backend.production.settings(ids.last),
          backend.cleanup.drafts,
        ]);
        try {
          final blocked = await diagnostic.preview(
            {'font_size'},
            ids,
            cleanup: true,
            append: true,
          );
          expect(blocked.ready, false);
          expect(blocked.errors.keys, [ids.last]);
          expect(blocked.production.keys, [ids.first]);
          expect(blocked.batchError, isNotEmpty);
          await expectLater(diagnostic.apply(blocked), throwsFormatException);
          expect(
            jsonEncode([
              backend.production.settings(ids.first),
              backend.production.settings(ids.last),
              backend.cleanup.drafts,
            ]),
            invalidBefore,
          );
        } finally {
          diagnostic.dispose();
          backend.draftFor(ids.last).coverPath = oldCover;
        }
        final originalRules = backend.cleanup.drafts[ids.first]!;
        backend.cleanup.drafts[ids.first] = {
          'kind': 'cleanup',
          'pipeline': [
            {'kind': 'regex_replace', 'pattern': '[', 'replace': ''},
          ],
        };
        final badCleaning = library.openBookBatch(ids.first);
        try {
          final blocked = await badCleaning.preview(
            {'author'},
            ids,
            cleanup: true,
            append: false,
          );
          expect(blocked.ready, false);
          expect(blocked.errors.length, 2);
          expect(blocked.production.length, 2);
          await expectLater(badCleaning.apply(blocked), throwsFormatException);
          expect(backend.cleanup.drafts[ids.last], isNull);
        } finally {
          badCleaning.dispose();
          backend.cleanup.drafts[ids.first] = originalRules;
        }
        final session = library.openBookBatch(ids.first);
        final before = jsonEncode([
          backend.production.settings(ids.last),
          backend.cleanup.drafts,
          backend.cleanup.histories,
        ]);
        var plan = await session.preview(
          {'author', 'font_size', 'cover'},
          [ids.last],
          cleanup: true,
          append: true,
        );
        expect(plan.production[ids.last]!.after['font_size'], 25.0);
        expect(plan.cleanup!.items.single.changes, 2);
        expect((await session.differences(plan, ids.last)).actions.length, 2);
        expect(
          jsonEncode([
            backend.production.settings(ids.last),
            backend.cleanup.drafts,
            backend.cleanup.histories,
          ]),
          before,
        );
        // Production validation fails after cleanup has already prepared its result.
        await cover.writeAsBytes([0, 1, 2]);
        try {
          await expectLater(session.apply(plan), throwsA(anything));
        } finally {
          await cover.writeAsBytes(bytes);
        }
        expect(
          jsonEncode([
            backend.production.settings(ids.last),
            backend.cleanup.drafts,
            backend.cleanup.histories,
          ]),
          before,
        );
        plan = await session.preview(
          {'author', 'font_size', 'cover'},
          [ids.last],
          cleanup: true,
          append: true,
        );
        var publications = 0;
        void observer() {
          publications++;
          expect(backend.production.settings(ids.last)['author'], '批量作者');
          expect(backend.production.settings(ids.last)['font_size'], 25.0);
          expect(backend.cleanup.drafts[ids.last], isNotNull);
        }

        backend.addListener(observer);
        await session.apply(plan);
        backend.removeListener(observer);
        expect(publications, 1);
        await expectLater(session.apply(plan), throwsA(anything));
        session.dispose();
        final project =
            '${root.absolute.path}/mixed-${DateTime.now().microsecondsSinceEpoch}.easypub.json';
        expect(await backend.saveProjectOutcome(project), true);
        expect(await backend.openProjectOutcome(project), true);
        final target = backend.shelf.books.singleWhere(
          (b) => !b.isDemo && b.path.endsWith('乙.txt'),
        );
        expect(backend.production.settings(target.id)['author'], '批量作者');
        expect(backend.production.settings(target.id)['font_size'], 25.0);
        expect(backend.cleanup.drafts[target.id], isNotNull);
        for (final name in ['甲', '乙']) {
          expect(await File('${root.path}/$name.txt').readAsString(), original);
        }
      } finally {
        library.dispose();
        backend.dispose();
      }
    });
  });
}
