import 'package:easypub_desktop/prototype/output_batch.dart';
import 'package:easypub_desktop/prototype/conversion_preflight.dart';
import 'package:easypub_desktop/prototype/output_task.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/state/output_store.dart';
import 'package:flutter_test/flutter_test.dart';

class BatchState extends PrototypeState {
  BatchState()
    : super(
        importer: (p, _) async => ImportedTxt(
          path: p,
          sourceId: p,
          revision: 1,
          encoding: 'utf-8',
          lines: 2,
          headings: 1,
        ),
      );
  final guards = <String, String>{};
  @override
  String conversionContext(String bookId) => guards[bookId] ?? 'original';
  @override
  Map<String, dynamic> publicationRequest(String bookId) => {
    'settings': {'language': 'zh'},
    'book': bookId,
  };
}

class StoredBatchState extends BatchState {
  bool enabled = false;
  int failAt = 0;
  final savedStates = <String>[];
  final savedRecords = <Map<String, dynamic>>[];
  @override
  String? get settingsDirectory => enabled ? r'D:\test-settings' : null;
  // V20：保存任务与批次记录的方法在 OutputStore 上，测试替换它来模拟保存失败。
  @override
  OutputStore createOutputs() => _StoredOutputs(this);
}

class _StoredOutputs extends OutputStore {
  _StoredOutputs(this.owner) : super(owner);
  final StoredBatchState owner;
  @override
  Future<void> persist(OutputTask task) async {}
  @override
  Future<bool> saveBatchRecord(Map<String, dynamic> record) async {
    owner.savedStates.add(record['state'] as String);
    owner.savedRecords.add(record);
    return owner.savedStates.length != owner.failAt;
  }
}

void main() {
  test(
    'late stop after the only committed file remains complete in batch record',
    () async {
      final state = StoredBatchState();
      addTearDown(state.dispose);
      await state.importBookOutcome(r'D:\last.txt');
      state.enabled = true;
      late OutputBatch batch;
      batch = OutputBatch(
        state,
        [state.currentId],
        epubCall: (r) async {
          if (r['op'] == 'preview') return {'plan_id': 'one'};
          await batch.stop();
          return {'committed': true};
        },
      );
      await batch.previewAll(() {});
      await batch.commitAll(() {});
      expect(state.savedStates.last, 'complete');
      expect(batch.items.single.phase, 'complete');
      expect(batch.items.single.failed, false);
      expect(state.outputs.tasks.single.phase, 'complete');
    },
  );

  for (final failAt in [0, 1, 2]) {
    test(
      'batch persistence failure $failAt stops writes and releases busy state',
      () async {
        final state = StoredBatchState();
        addTearDown(state.dispose);
        await state.importBookOutcome(r'D:\a.txt');
        final a = state.currentId;
        await state.importBookOutcome(r'D:\b.txt');
        final b = state.currentId;
        state.enabled = true;
        state.failAt = failAt;
        var commits = 0;
        final batch = OutputBatch(
          state,
          [a, b],
          epubCall: (request) async {
            if (request['op'] == 'preview') return {'plan_id': 'p'};
            commits++;
            return {'committed': true};
          },
        )..parallelOverride = 1; // V38：本测试检验逐本时“保存失败即停止后续”。
        await batch.previewAll(() {});
        if (failAt == 0) {
          await batch.commitAll(() {});
          // R6：每本完成后的“进行中”记录合并保存、最多每 10 秒一次，批次结束由最终保存代替。
          expect(state.savedStates.first, 'running');
          expect(state.savedStates.last, 'complete');
          expect(state.savedStates.length, lessThanOrEqualTo(4));
          expect(commits, 2);
        } else {
          await expectLater(batch.commitAll(() {}), throwsFormatException);
          // 开始前的记录存不下：一本都不写。进行中的记录存不下：发现失败后不再开始新书
          // （R6 起不再逐本等保存，失败被发现前已开始的那本仍会完成），结束时报错。
          expect(commits, failAt == 1 ? 0 : lessThanOrEqualTo(2));
          expect(state.savedStates, isNot(contains('complete')));
        }
        expect(batch.busy, false);
        expect(state.outputs.batchBusy, false);
      },
    );
  }
  test('batch freezes selection, commits sequentially, preserves failures and cannot repeat', () async {
    final state = BatchState();
    addTearDown(state.dispose);
    await state.importBookOutcome(r'D:\a.txt');
    final a = state.currentId;
    await state.importBookOutcome(r'D:\b.txt');
    final b = state.currentId;
    final ids = [a, b];
    final commits = <String>[];
    final batch = OutputBatch(
      state,
      ids,
      epubCall: (r) async {
        final id = (r['publication'] as Map)['book'] as String;
        if (r['op'] == 'preview') return {'plan_id': id};
        commits.add(id);
        if (id == a) throw const FormatException('模拟单书失败');
        return {'committed': true};
      },
    );
    ids.clear();
    await batch.previewAll(() {});
    expect(batch.ready, true);
    expect(state.outputs.tasks, isEmpty);
    await batch.commitAll(() {});
    expect(commits, [a, b]);
    expect(state.outputs.tasks.map((t) => t.phase), ['failed', 'complete']);
    expect(state.queueActive, false);
    await batch.commitAll(() {});
    expect(commits, [a, b]);
    await batch.retryFailed(() {});
    expect(commits, [a, b, a]);
  });

  test('retry failed items keeps successful output terminal and creates a new task', () async {
    final state = BatchState();
    addTearDown(state.dispose);
    await state.importBookOutcome(r'D:\a.txt');
    final a = state.currentId;
    await state.importBookOutcome(r'D:\b.txt');
    final b = state.currentId;
    var firstAttempt = true;
    final calls = <String>[];
    final batch = OutputBatch(
      state,
      [a, b],
      epubCall: (r) async {
        final id = (r['publication'] as Map)['book'] as String;
        if (r['op'] == 'preview') return {'plan_id': id};
        calls.add(id);
        if (id == a && firstAttempt) {
          firstAttempt = false;
          throw const FormatException('一次性失败');
        }
        return {'committed': true};
      },
    );
    await batch.previewAll(() {});
    await batch.commitAll(() {});
    expect(calls, [a, b]);
    final successfulTask = state.outputs.tasks.singleWhere(
      (t) => t.bookId == b,
    );
    await batch.retryFailed(() {});
    expect(calls, [a, b, a]);
    expect(state.outputs.tasks.where((t) => t.bookId == b), [successfulTask]);
    expect(state.outputs.tasks.where((t) => t.bookId == a).length, 2);
    expect(batch.hasFailedItems, false);
  });
  test('stale preview and duplicate paths prevent writes; stop skips remaining books', () async {
    final state = BatchState();
    addTearDown(state.dispose);
    await state.importBookOutcome(r'D:\a.txt');
    final a = state.currentId;
    await state.importBookOutcome(r'D:\b.txt');
    final b = state.currentId;
    var commits = 0;
    late OutputBatch batch;
    batch = OutputBatch(
      state,
      [a, b],
      epubCall: (r) async {
        if (r['op'] == 'preview') return {'plan_id': 'plan'};
        commits++;
        await batch.stop();
        return {'committed': true};
      },
    )..parallelOverride = 1; // V38：逐本时“停止”跳过尚未开始的书。
    await batch.previewAll(() {});
    state.guards[a] = 'changed';
    await batch.commitAll(() {});
    expect(commits, 0);
    await batch.previewAll(() {});
    await batch.commitAll(() {});
    expect(commits, 1);
    expect(batch.items.last.status, contains('未执行'));
    batch.items.last.path = batch.items.first.path;
    await expectLater(batch.previewAll(() {}), throwsFormatException);
  });

  test('batch preflight is persisted as source-bound evidence', () async {
    final state = StoredBatchState();
    addTearDown(state.dispose);
    await state.importBookOutcome(r'D:\a.txt');
    state.enabled = true;
    final bookId = state.shelf.books.singleWhere((book) => !book.isDemo).id;
    final batch = OutputBatch(state, [bookId]);
    final reports = [
      const ConversionPreflightReport(
        bookId: 'book',
        title: '测试书',
        issues: [
          ConversionPreflightIssue(
            level: ConversionPreflightLevel.blocking,
            title: '章节问题待审阅',
            detail: '包含 number-gap',
            canOpenRepair: true,
            action: ConversionPreflightAction.chapters,
          ),
        ],
      ),
    ];
    final saved = await batch.persistPreflight(
      reports,
      acknowledged: false,
      stateName: 'preflight_blocked',
    );
    expect(saved, true);
    expect(state.savedStates, ['preflight_blocked']);
    final record = state.savedRecords.single;
    final restored =
        ((record['preflight'] as Map)['reports'] as List).single as Map;
    expect(restored['book_id'], 'book');
    expect((restored['issues'] as List).single['detail'], '包含 number-gap');
    final restoredIssue = ConversionPreflightIssue.fromJson(
      ((restored['issues'] as List).single as Map).cast<String, dynamic>(),
    );
    expect(restoredIssue.action, ConversionPreflightAction.chapters);
    expect(batch.ready, false);
  });
}
