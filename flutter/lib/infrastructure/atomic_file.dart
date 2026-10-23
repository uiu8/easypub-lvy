import 'dart:io';

/// 同目录写完并刷盘再替换；中断只留下临时目录，旧文件仍可读取。
Future<void> writeAtomicText(File target, String contents) async {
  await target.parent.create(recursive: true);
  final staging = await target.parent.createTemp('.easypub-write-');
  final pending = File('${staging.path}/pending');
  try {
    await pending.writeAsString(contents, flush: true);
    await pending.rename(target.path);
  } finally {
    if (await pending.exists()) await pending.delete();
    await staging.delete();
  }
}
