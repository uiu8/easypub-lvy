import 'dart:io';

import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/output_batch.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// R9 异常环境：路径含特殊字符与超长路径、原文件被其他程序独占、成品目标只读。
/// 真实 DLL、隔离设置目录；只验证“能完成或给出可读原因，不崩溃、不改原文件”。
void main() {
  late Directory root;
  late PrototypeState state;
  late LegacyLibraryAdapter library;

  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
  });

  setUp(() async {
    root = (await Directory.systemTemp.createTemp('r9-abnormal-')).absolute;
    state = PrototypeState(settingsDirectory: '${root.path}/settings');
    library = LegacyLibraryAdapter(backend: state);
    await library.load();
    await library.savePatch({'check_after_import': false});
  });

  tearDown(() async {
    library.dispose();
    state.dispose();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  String body(String title) =>
      [for (var c = 1; c <= 3; c++) '第$c章 $title$c\n　　正文$c。\n'].join();

  Future<OutputBatch> epubBatch(String id, String output) async {
    final info = library.openBookInformation(id);
    await info.apply(await info.preview({'language': 'zh-CN', 'author': '测试'}));
    info.dispose();
    final batch = OutputBatch(state, [id])
      ..parallelOverride = 1
      ..checksEnabled = false;
    batch.items.single.path = output;
    return batch;
  }

  test('特殊字符与超过 260 字符的路径：导入、转换都能完成，原文件不变', () async {
    // 空格、&、#、%、方括号、全角符号、表情；目录层层嵌套到总长超过 260。
    var dir = Directory('${root.path}/书 稿 & #1 %20 [测试]（全角）😀');
    while (dir.path.length < 280) {
      dir = Directory('${dir.path}/很长的子目录名称-abcdefghij');
    }
    await dir.create(recursive: true);
    final file = File('${dir.path}/雾港 & 来信 #2 [完整版].txt');
    await file.writeAsString(body('雾起'));
    final before = await file.readAsBytes();
    expect(file.path.length, greaterThan(260));

    final result = (await library.importFiles([file.path])).single;
    expect(result.succeeded, true, reason: result.message);
    final id = state.currentId;

    final output = '${dir.path}/成品 & #2 [测试].epub';
    final batch = await epubBatch(id, output);
    await batch.previewAll(() {});
    expect(
      batch.items.single.preview,
      isNotNull,
      reason: batch.items.single.status,
    );
    await batch.commitAll(() {});
    expect(
      batch.items.single.phase,
      'complete',
      reason: batch.items.single.status,
    );
    expect(File(output).existsSync(), true);
    expect(await file.readAsBytes(), before);
  });

  test('原文件被其他程序独占：导入给出原因，不崩溃', () async {
    final file = File('${root.path}/被占用.txt');
    await file.writeAsString(body('占用'));
    final handle = await file.open(mode: FileMode.append);
    await handle.lock(FileLock.exclusive);
    try {
      final result = (await library.importFiles([file.path])).single;
      // ignore: avoid_print
      print('R9 独占导入：${result.succeeded ? "导入成功" : result.message}');
      if (result.succeeded) {
        // 某些系统只锁写入不锁读取：能导入也是可接受的结果，但必须真的读到了正文。
        expect(library.books.value, isNotEmpty);
      } else {
        expect(result.message.trim(), isNotEmpty);
        expect(result.message, isNot(contains('Exception')));
      }
    } finally {
      await handle.unlock();
      await handle.close();
    }
  });

  test('成品目标是只读文件：转换给出原因，只读文件不被改动', () async {
    final file = File('${root.path}/只读目标.txt');
    await file.writeAsString(body('只读'));
    expect((await library.importFiles([file.path])).single.succeeded, true);
    final id = state.currentId;
    final output = File('${root.path}/只读目标.epub');
    await output.writeAsString('旧内容');
    await Process.run('attrib', ['+R', output.path]);
    addTearDown(() => Process.run('attrib', ['-R', output.path]));

    final batch = await epubBatch(id, output.path);
    await batch.previewAll(() {});
    if (batch.items.single.preview != null) {
      await batch.commitAll(() {});
      expect(batch.items.single.phase, isNot('complete'));
    }
    final status = batch.items.single.status;
    // ignore: avoid_print
    print('R9 只读目标：$status');
    expect(status.trim(), isNotEmpty);
    expect(status, isNot(contains('Exception')));
    expect(await output.readAsString(), '旧内容');
  });
}
