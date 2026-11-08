import 'package:easypub_desktop/prototype/output_task.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('output task records retain batch identity across serialization', () {
    final task = OutputTaskForTest.make();
    final restored = OutputTask.fromRecord(task.toRecord());
    expect(restored.batchId, 'batch-1');
    expect(restored.batchIndex, 2);
    expect(restored.batchTotal, 4);
    expect(restored.outputPath, r'D:\book.epub');
  });

  // V21：原测试的旧原型“历史页”部分已随旧界面移除，状态部分保留。
  test(
    'output records retain source identity and confirmed terminal state',
    () async {
      final state = PrototypeState(
        importer: (p, _) async => ImportedTxt(
          path: p,
          sourceId: p,
          revision: 1,
          encoding: 'utf-8',
          lines: 3,
          headings: 1,
        ),
      );
      addTearDown(state.dispose);
      await state.importBookOutcome(r'D:\output-a.txt');
      final task = state.outputs.begin(state.currentId, 'AZW3', r'D:\a.azw3');
      state.outputs.update(task, 'converting');
      expect(task.terminal, false);
      state.outputs.update(task, 'cancelled', terminal: true);
      state.outputs.update(task, 'failed', terminal: true);
      expect(task.phase, 'cancelled');
      await state.importBookOutcome(r'D:\output-b.txt');
      expect(state.outputs.tasks.single.sourceId, r'D:\output-a.txt');
    },
  );
}

class OutputTaskForTest {
  static OutputTask make() => OutputTask(
    bookId: 'book',
    title: '书',
    sourceId: 'source',
    revision: 1,
    format: 'EPUB',
    outputPath: r'D:\book.epub',
    batchId: 'batch-1',
    batchIndex: 2,
    batchTotal: 4,
  );
}
