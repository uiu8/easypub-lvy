import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';

void main() {
  testWidgets('new conversion session preflight preview confirm and three outputs', (
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
      final parent = Directory('../artifacts/frontend-rewrite/conversion');
      await parent.create(recursive: true);
      final root = await parent.createTemp('run-');
      final backend = PrototypeState(
        settingsDirectory: '${root.absolute.path}/settings',
      );
      final library = LegacyLibraryAdapter(backend: backend);
      final session = library.openConversion();
      try {
        final source = File('${root.path}/转换样书.txt');
        const text = '第一章 来信\n河边来了一封信。\n第二章 夜渡\n天色晚了。\n';
        await source.writeAsString(text);
        await backend.importBookOutcome(source.absolute.path);
        final id = backend.currentId;
        final destination = Directory('${root.absolute.path}/output');
        await destination.create();
        final blocked = await session.preview(
          ConversionRequest(
            books: [id],
            directory: destination.path,
            format: 'AZW3',
          ),
        );
        expect(blocked.blocked, true);
        expect(blocked.previewed, false);
        await expectLater(
          session.commit(blocked, acknowledgeWarnings: true),
          throwsFormatException,
        );
        expect(await destination.list().isEmpty, true);
        final unchanged = jsonEncode(backend.production.settings(id));
        for (final policyFormat in ['EPUB', 'AZW3', 'MOBI']) {
          final policyPlan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: destination.path,
              format: policyFormat,
              engine:
                  (Platform.environment['EASYPUB_TEST_KINDLING'] ??
                  r'D:\software\DeepSeek-Harness\workspace\ebook-bench\kindling.exe'),
              language: 'en',
              generateCover: true,
            ),
          );
          expect(
            policyPlan.blocked,
            false,
            reason: policyPlan.findings
                .map((f) => '${f.title}: ${f.detail}')
                .join('\n'),
          );
          expect(policyPlan.findings.any((f) => f.title == '本次生成文字封面'), true);
          expect(policyPlan.findings.any((f) => f.title == '语言：en'), true);
          expect(jsonEncode(backend.production.settings(id)), unchanged);
          final policyOutput = await session.commit(
            policyPlan,
            acknowledgeWarnings: true,
          );
          expect(policyOutput.single.complete, true);
          expect(policyOutput.single.coverPath, isNotNull);
          expect(await File(policyOutput.single.coverPath!).exists(), true);
          if (policyFormat == 'EPUB') {
            final inspected = await Process.run('python', [
              '-c',
              'import zipfile,sys,json,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); p=next(n for n in z.namelist() if n.endswith(".opf")); r=E.fromstring(z.read(p)); print(json.dumps({"languages":[x.text for x in r.iter() if x.tag.endswith("}language")],"covers":[x.attrib for x in r.iter() if "cover-image" in x.attrib.get("properties","")] }))',
              policyOutput.single.path,
            ]);
            expect(inspected.exitCode, 0, reason: inspected.stderr.toString());
            final package = jsonDecode(inspected.stdout as String) as Map;
            expect(package['languages'], ['en']);
            expect(package['covers'], hasLength(1));
            final history = library.openOutputHistory();
            await history.load();
            final inspectedPackage = await history.inspectPackage(
              policyOutput.single.taskId!,
            );
            expect(inspectedPackage.metadataStatus, 'matches');
            expect(
              inspectedPackage.expectedMetadata['language'],
              'en',
              reason: 'snapshot uses per-export override, not the current book language',
            );
            expect(inspectedPackage.metadataMismatches, isEmpty);
          } else {
            final bytes = await File(policyOutput.single.path).readAsBytes();
            expect(ascii.decode(bytes.sublist(60, 68)), 'BOOKMOBI');
          }
          expect(jsonEncode(backend.production.settings(id)), unchanged);
          expect(await source.readAsString(), text);
        }
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.green, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1200, 1600);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        picture.dispose();
        final cover = File('${root.path}/cover.png');
        await cover.writeAsBytes(bytes);
        final info = library.openBookInformation(id);
        await info.apply(
          await info.preview({
            'author': '测试作者',
            'language': 'zh-CN',
            'cover_path': cover.absolute.path,
          }),
        );
        info.dispose();
        for (final naming in ['title_author', 'filename']) {
          expect(await library.savePatch({'output_naming': naming}), true);
          final named = await session.preview(
            ConversionRequest(
              books: [id],
              directory: '${root.absolute.path}/naming',
              format: 'EPUB',
            ),
          );
          expect(named.blocked, false);
          expect(
            named.outputs.single.path,
            endsWith(
              naming == 'title_author' ? '转换样书 - 测试作者.epub' : '转换样书.epub',
            ),
          );
          await session.cancel();
        }
        await library.savePatch({
          'output_naming': 'title',
          'output_collision_policy': 'ask',
        });
        final askFile = File('${destination.path}/转换样书.epub');
        await askFile.writeAsString('keep-this-file');
        final asked = await session.preview(
          ConversionRequest(
            books: [id],
            directory: destination.path,
            format: 'EPUB',
          ),
        );
        expect(asked.findings.any((f) => f.title == '同名文件需要确认'), true);
        await expectLater(
          session.commit(asked, acknowledgeWarnings: false),
          throwsFormatException,
        );
        expect(await askFile.readAsString(), 'keep-this-file');
        await session.cancel();
        await library.savePatch({'output_collision_policy': 'preserve'});
        final settings = jsonEncode(backend.production.settings(id));
        final collision = File('${destination.path}/转换样书.epub');
        await collision.writeAsString('existing-output');
        final engine =
            (Platform.environment['EASYPUB_TEST_KINDLING'] ??
            r'D:\software\DeepSeek-Harness\workspace\ebook-bench\kindling.exe');
        for (final format in ['EPUB', 'AZW3', 'MOBI']) {
          final request = ConversionRequest(
            books: [id],
            directory: destination.path,
            format: format,
            engine: engine,
          );
          var plan = await session.preview(request);
          expect(
            plan.blocked,
            false,
            reason: plan.findings
                .map((f) => '${f.title}: ${f.detail}')
                .join('\n'),
          );
          expect(
            plan.previewed,
            true,
            reason: plan.outputs.map((o) => o.status).join('\n'),
          );
          final destinationCheck = plan.groups.firstWhere(
            (g) => g.key == 'destination',
          );
          expect(destinationCheck.level, 'pass');
          expect(
            destinationCheck.items.single.detail,
            contains(plan.outputs.single.path),
          );
          expect(jsonEncode(backend.production.settings(id)), settings);
          expect(plan.outputs.single.coverPath, cover.absolute.path);
          expect(await File(plan.outputs.single.path).exists(), false);
          if (format == 'EPUB') {
            expect(plan.outputs.single.path, isNot(collision.path));
            await session.cancel();
            await expectLater(
              session.commit(plan, acknowledgeWarnings: true),
              throwsFormatException,
            );
            plan = await session.preview(request);
          }
          final result = await session.commit(plan, acknowledgeWarnings: false);
          expect(result.single.status, '已完成');
          expect(result.single.complete, true);
          await backend.outputs.historySaved;
          expect(
            await destination
                .list()
                .where((entry) => entry is Directory)
                .toList(),
            isEmpty,
            reason: '成功输出目录只留成品',
          );
          expect(result.single.format, format);
          final data = await File(result.single.path).readAsBytes();
          expect(data.length, greaterThan(100));
          if (format == 'EPUB') {
            expect(data.take(2), [80, 75]);
          } else {
            expect(ascii.decode(data.sublist(60, 68)), 'BOOKMOBI');
            final history = library.openOutputHistory();
            await history.load();
            final inspected = await history.inspectPackage(
              result.single.taskId!,
            );
            expect(inspected.status, 'kindle_container_checked');
            expect(inspected.inspected, false);
            final output = File(result.single.path);
            try {
              await output.writeAsBytes([...data, 0]);
              final changed = await history.inspectPackage(
                result.single.taskId!,
              );
              expect(changed.status, 'failed');
              expect(changed.detail, contains('哈希不一致'));
            } finally {
              await output.writeAsBytes(data);
            }
          }
          await expectLater(
            session.commit(plan, acknowledgeWarnings: true),
            throwsFormatException,
          );
          expect(await collision.readAsString(), 'existing-output');
          expect(await source.readAsString(), text);
          expect(jsonEncode(backend.production.settings(id)), settings);
        }
        // Auto generation must not hide an existing but broken cover reference.
        final heldCover = await cover.rename('${cover.path}.held');
        try {
          final brokenCover = await session.preview(
            ConversionRequest(
              books: [id],
              directory: destination.path,
              format: 'EPUB',
              generateCover: true,
            ),
          );
          expect(brokenCover.blocked, true);
          expect(brokenCover.findings.any((f) => f.title == '本次生成文字封面'), false);
          expect(jsonEncode(backend.production.settings(id)), settings);
        } finally {
          await heldCover.rename(cover.path);
        }
        final retryRequest = ConversionRequest(
          books: [id],
          directory: destination.path,
          format: 'EPUB',
        );
        final raced = await session.preview(retryRequest);
        final occupied = File(raced.outputs.single.path);
        await occupied.writeAsString('created-after-preview');
        final failed = await session.commit(raced, acknowledgeWarnings: true);
        expect(failed.single.failed, true);
        expect(failed.single.complete, false);
        expect(failed.single.detail, isNotEmpty);
        expect(await occupied.readAsString(), 'created-after-preview');
        final fresh = await session.preview(retryRequest);
        expect(fresh.outputs.single.path, isNot(occupied.path));
        final retried = await session.commit(fresh, acknowledgeWarnings: true);
        expect(retried.single.complete, true);
        expect(await occupied.readAsString(), 'created-after-preview');
        expect(await source.readAsString(), text);
        expect(jsonEncode(backend.production.settings(id)), settings);
        final unreviewed = File('${root.path}/未审阅跳号.txt');
        const unreviewedText = '第一章 来信\n河边来信。\n第三章 夜渡\n编号有跳跃，保留原文。\n';
        await unreviewed.writeAsString(unreviewedText);
        await backend.importBookOutcome(unreviewed.absolute.path);
        final unreviewedId = backend.currentId;
        for (final checkFirst in [true, false]) {
          final optionalPlan = await session.preview(
            ConversionRequest(
              books: [unreviewedId],
              directory: destination.path,
              format: 'EPUB',
              language: 'zh-CN',
              runChecks: checkFirst,
            ),
          );
          expect(optionalPlan.previewed, true);
          expect(session.isCurrent(optionalPlan), true);
          if (checkFirst) {
            expect(
              optionalPlan.findings.any(
                (f) => f.category == 'chapters' && f.level != 'pass',
              ),
              true,
            );
          } else {
            expect(
              optionalPlan.findings.any((f) => f.category == 'chapters'),
              false,
            );
          }
          final converted = await session.commit(
            optionalPlan,
            acknowledgeWarnings: false,
          );
          expect(converted.single.complete, true);
          expect(await unreviewed.readAsString(), unreviewedText);
        }
        final feed = session as ConversionTaskFeed;
        await feed.loadTaskFeed();
        final tasks = feed.taskFeed;
        expect(tasks.map((t) => t.taskId).toSet().length, tasks.length);
        expect(
          tasks.map((t) => t.format).toSet(),
          containsAll(['EPUB', 'AZW3', 'MOBI']),
        );
        expect(tasks.where((t) => t.historical), isNotEmpty);
        expect(
          session.outputs,
          hasLength(1),
          reason: 'task history must not change commit output scope',
        );
        final reopened = PrototypeState(
          settingsDirectory: backend.settingsDirectory,
        );
        final reopenedLibrary = LegacyLibraryAdapter(backend: reopened);
        final reopenedSession = reopenedLibrary.openConversion();
        final savedCover = await cover.readAsBytes();
        final coverTask = tasks.firstWhere((t) => t.coverThumbnail != null);
        final frozenCover = List<int>.of(coverTask.coverThumbnail!);
        expect(frozenCover.length, lessThanOrEqualTo(12 * 1024));
        await cover.writeAsString('original cover changed after conversion');
        try {
          final restoredFeed = reopenedSession as ConversionTaskFeed;
          await restoredFeed.loadTaskFeed();
          expect(
            restoredFeed.taskFeed.map((t) => t.format).toSet(),
            containsAll(['EPUB', 'AZW3', 'MOBI']),
          );
          expect(restoredFeed.taskFeed.every((t) => t.historical), true);
          expect(
            restoredFeed.taskFeed.every(
              (t) => t.checksEnabled != null && t.coverPath == null,
            ),
            true,
          );
          expect(
            restoredFeed.taskFeed.map((t) => t.checksEnabled).toSet(),
            containsAll([true, false]),
          );
          expect(
            restoredFeed.taskFeed
                .firstWhere((t) => t.taskId == coverTask.taskId)
                .coverThumbnail,
            frozenCover,
          );
          expect(reopenedSession.outputs, isEmpty);
        } finally {
          await cover.writeAsBytes(savedCover);
          reopenedSession.dispose();
          reopenedLibrary.dispose();
          reopened.dispose();
        }
      } finally {
        session.dispose();
        library.dispose();
        backend.dispose();
      }
    });
  });
}
