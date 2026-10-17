import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('EPUB stop stays pending until current publication settles and skips next book', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('completion-epub-stop-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final reached = Completer<void>(), release = Completer<void>();
    var commits = 0;
    final session = LegacyConversionSession(
      state,
      epubCall: (request) async {
        if (request['op'] == 'commit') {
          commits++;
          reached.complete();
          await release.future;
        }
        return (jsonDecode(
          await api.epubExportText(requestJson: jsonEncode(request)),
        ) as Map).cast<String, dynamic>();
      },
    );
    Future<List<ConversionOutput>>? running;
    try {
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'parallel_books': '1',
      });
      final files = [
        for (final name in ['当前', '下一本'])
          File('${root.path}/$name.txt')..writeAsStringSync('第一章 开始\n合成正文。\n'),
      ];
      expect(
        (await library.importFiles(files.map((f) => f.path).toList()))
            .every((o) => o.succeeded),
        true,
      );
      final plan = await session.preview(
        ConversionRequest(
          books: library.books.value.map((b) => b.id).toList(),
          directory: '${root.path}/output',
          format: 'EPUB',
          runChecks: false,
        ),
      );
      running = session.commit(plan, acknowledgeWarnings: true);
      await reached.future;
      expect(
        session.outputs.first.phase,
        'converting',
        reason: 'EPUB commit must expose its actual running stage',
      );
      await session.cancel();
      expect(session.busy, true);
      expect(session.outputs.first.running, true);
      expect(session.outputs.first.stopRequested, true);
      expect(session.outputs.first.waitingForCurrentFile, true);
      expect(
        session.outputs.first.cancelRequested,
        false,
        reason: 'Stopping the queue did not cancel the in-flight native call',
      );
      release.complete();
      await running;
      expect(session.busy, false);
      expect(commits, 1);
      expect(session.outputs.map((o) => o.phase), ['complete', 'cancelled']);
      expect(await File(session.outputs.first.path).exists(), true);
      expect(await File(session.outputs.last.path).exists(), false);
      final record = state.outputs.batchRecords.single;
      expect((record['items'] as List).map((i) => i['phase']), [
        'complete',
        'cancelled',
      ]);
    } finally {
      if (!release.isCompleted) release.complete();
      await running;
      session.dispose();
      library.dispose();
      state.dispose();
    }
  });
}
