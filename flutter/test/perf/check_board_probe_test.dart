// 检查进度的耗时探针，只在设了 EASYPUB_CHECK_PROBE 时运行。
// 新旧做法在同一次运行里交替测（书稿存储重构起的规矩），避免不同时段的数字并列。
import 'dart:io';

import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_book_check_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

final _root = Platform.environment['EASYPUB_CHECK_PROBE'];

/// 取三次的中位数。
Future<int> _ms(Future<void> Function() body, [int rounds = 3]) async {
  final samples = <int>[];
  for (var i = 0; i < rounds; i++) {
    final watch = Stopwatch()..start();
    await body();
    samples.add(watch.elapsedMilliseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

Future<void> _probe(String name, String path) async {
  final dir = await Directory(_root!).createTemp('probe-');
  final state = PrototypeState(settingsDirectory: '${dir.path}/settings');
  final library = LegacyLibraryAdapter(backend: state);
  await library.load();
  await library.savePatch({'check_after_import': false});
  expect((await library.importFiles([path])).single.succeeded, true);
  final id = library.books.value.single.id;
  final checks = library.openChecks(id);
  final update = checks as CheckUpdateSession;
  final chapters = library.openChapters(id);
  final out = StringBuffer('--- $name (${File(path).lengthSync()} bytes)\n');

  final first = Stopwatch()..start();
  await checks.inspect();
  out.writeln('首次全量检查 ${first.elapsedMilliseconds} ms');
  var tree = await chapters.read(0);
  final total = (await chapters.issues(tree, 0, effective: true)).total;
  final spots = await update.spots();
  out.writeln('章节问题 $total 条，文本问题 ${spots.length} 处');

  // 取全书待处理：旧做法逐页读（最多 2000 条），新做法一次拿整数列表。
  Future<void> paged() async {
    var offset = 0;
    while (offset < 2000 && offset < total) {
      final page = await chapters.issues(tree, offset, effective: true);
      if (page.items.isEmpty) break;
      offset += page.items.length;
    }
  }

  Future<void> queued() async =>
      (chapters as ChapterIssueQueueSession).issueQueue(tree);
  for (var round = 0; round < 3; round++) {
    out.writeln(
      '第 ${round + 1} 轮 旧逐页读 ${await _ms(paged, 1)} ms / 新位置列表 ${await _ms(queued, 1)} ms',
    );
  }
  out.writeln(
    '翻到中间一页 ${await _ms(() async => chapters.issues(tree, total ~/ 100 * 50, effective: true))} ms',
  );

  // 改一个字段：旧做法整份重查，新做法只算书籍信息。改一个标题：两边都重算章节和文本。
  var flip = 0;
  Future<void> metadata() async {
    flip++;
    final info = library.openBookInformation(id);
    await info.apply(
      await info.preview({...info.saved, 'publisher': '出版社$flip'}),
    );
    info.dispose();
  }

  for (var round = 0; round < 3; round++) {
    await metadata();
    final full = await _ms(() async {
      await checks.inspect();
    }, 1);
    await metadata();
    final part = await _ms(() async {
      await update.update();
    }, 1);
    out.writeln('改出版者后 第 ${round + 1} 轮 旧整份重查 $full ms / 新按项更新 $part ms');
  }
  await metadata();
  await update.update();
  final session = library.openChecks(id) as CheckUpdateSession;
  Future<void> rename() async {
    flip++;
    tree = await chapters.read(0);
    await chapters.rename(tree, tree.nodes[2].id, '第三章 新名字$flip');
    tree = await chapters.read(0);
  }

  for (var round = 0; round < 3; round++) {
    await rename();
    final full = await _ms(() async {
      await checks.inspect();
    }, 1);
    await rename();
    final part = await _ms(() async {
      await session.update();
    }, 1);
    out.writeln('改标题后 第 ${round + 1} 轮 旧整份重查 $full ms / 新按项更新 $part ms');
  }

  // 改标题后第一次读位置（要等新的检查结果），和结果已有时再读一次。
  await rename();
  final cold = await _ms(() async {
    await (chapters as ChapterIssueQueueSession).issueQueue(tree);
  }, 1);
  final warm = await _ms(() async {
    await (chapters as ChapterIssueQueueSession).issueQueue(tree);
  });
  out.writeln('改标题后读位置 第一次 $cold ms / 再读 $warm ms');
  final spot = await _ms(() async {
    await update.spots();
  }, 1);
  out.writeln('改标题后读文本位置 $spot ms');
  // 重启后第一次要文本位置：旧做法跑一遍清理，新做法读存好的文件。
  await update.update();
  final cleanup = library.openCleanup(id);
  for (var round = 0; round < 3; round++) {
    LegacyBookCheckSession.forgetSpots(state);
    final old = await _ms(() async {
      await (cleanup as dynamic).recheck(positions: true);
    }, 1);
    LegacyBookCheckSession.forgetSpots(state);
    final fresh = await _ms(() async {
      await update.spots();
    }, 1);
    out.writeln('重启后读文本位置 第 ${round + 1} 轮 旧跑清理 $old ms / 新读文件 $fresh ms');
  }
  cleanup.dispose();
  final last = (spots.length ~/ 40 - 1).clamp(0, 1 << 30) * 40;
  for (var round = 0; round < 3; round++) {
    final at = (round + 1) * last ~/ 3 ~/ 40 * 40;
    out.writeln(
      '检查页翻到第 $at 条 ${await _ms(() async {
        await update.cleanupItemsAt(at);
      }, 1)} ms',
    );
  }
  // ignore: avoid_print
  print(out);
  checks.dispose();
  (session as BookCheckSession).dispose();
  library.dispose();
  state.dispose();
}

void main() {
  test(
    '检查进度耗时',
    skip: _root == null ? '只在探针时运行' : false,
    timeout: const Timeout(Duration(minutes: 30)),
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      for (final path in Platform.environment['EASYPUB_CHECK_BOOKS']!.split(
        ';',
      )) {
        await _probe(path.split(RegExp(r'[\\/]')).last, path);
      }
    },
  );
}
