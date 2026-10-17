import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('real import deduplicates paths and keeps the selection', () async {
    final s = PrototypeState(
      importer: (path, cancelled) async => ImportedTxt(
        path: path,
        sourceId: 'a' * 64,
        revision: 1,
        encoding: 'utf-8',
        lines: 10,
        headings: 2,
      ),
    );
    addTearDown(s.dispose);
    await s.importBookOutcome(r'D:\books\真实.txt');
    await s.importBookOutcome(r'D:\books\真实.txt');
    expect(s.shelf.books.length, 5);
    expect(s.current.isDemo, false);
    expect(s.shelf.selected, {'river', 'mountain'});
  });
  test('failed import preserves library and current book', () async {
    final s = PrototypeState(
      importer: (_, _) async => throw const FormatException('文件不存在'),
    );
    addTearDown(s.dispose);
    s.currentId = 'rain';
    await s.importBookOutcome(r'D:\missing.txt');
    expect(s.currentId, 'rain');
    expect(s.shelf.books.length, 4);
    expect(s.importing, false);
    expect(s.importStatus, '文件不存在');
  });

  // V39：取消导入曾把一个只有旧文件夹导入才会重置的标志永久置位，之后每次导入都直接失败。
  test('cancelling one import does not block later imports', () async {
    final s = PrototypeState(
      importer: (path, _) async => ImportedTxt(
        path: path,
        sourceId: 'f' * 64,
        revision: 1,
        encoding: 'utf-8',
        lines: 2,
        headings: 1,
      ),
    );
    addTearDown(s.dispose);
    s.cancelImport();
    expect(await s.importBookOutcome(r'D:\books\取消后.txt'), true);
    expect(s.current.path, r'D:\books\取消后.txt');
  });
}
