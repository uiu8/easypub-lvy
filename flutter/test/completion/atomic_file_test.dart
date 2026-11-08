import 'dart:io';

import 'package:easypub_desktop/infrastructure/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('原子替换并发写入不串文件；替换失败保留旧内容', () async {
    final root = await Directory.systemTemp.createTemp('easypub-atomic-');
    addTearDown(() => root.delete(recursive: true));
    final targets = [File('${root.path}/甲.json'), File('${root.path}/甲.txt')];
    await Future.wait([
      for (var i = 0; i < targets.length; i++)
        writeAtomicText(targets[i], '$i' * 4096),
    ]);
    for (var i = 0; i < targets.length; i++) {
      expect(await targets[i].readAsString(), '$i' * 4096);
    }
    final blocked = await Directory('${root.path}/blocked').create();
    final original = File('${blocked.path}/keep.txt');
    await original.writeAsString('保留');
    await expectLater(
      writeAtomicText(File(blocked.path), '新数据'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await original.readAsString(), '保留');
    expect(
      await root
          .list()
          .where((e) => e.path.contains('.easypub-write-'))
          .isEmpty,
      isTrue,
    );
  });
}
