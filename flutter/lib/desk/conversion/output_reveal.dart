// 打开某次输出所在的文件夹（V18，LIB-113）。
import 'dart:io';

import '../../application/conversion_desktop.dart';
import '../../application/output_history_service.dart';

/// 成品还在时打开文件夹并选中它；不在时打开输出文件夹，文件夹也不在时由桌面层报出原因。
Future<void> revealOutput(
  ConversionDesktop desktop,
  OutputRecord record,
) async {
  if (desktop is BookSourceDesktop && await File(record.path).exists()) {
    return (desktop as BookSourceDesktop).revealSource(record.path);
  }
  return desktop.openDirectory(record.directory);
}
