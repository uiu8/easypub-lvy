import 'dart:io';

import 'package:flutter/services.dart';

import 'tokens.dart';

/// 从系统字体目录登记编辑台字体族。思源黑体/宋体可变字体不存在时依次回落到
/// 微软雅黑、宋体、Consolas；全部缺失时由主题的 fontFamilyFallback 接手。
/// 字体不打包进安装包（思源黑体、宋体可变字体分别约 17 MB、25 MB），见 docs/37 第 2 节。
Future<void> loadDeskFonts({String? fontsDirectory}) async {
  final root =
      fontsDirectory ??
      '${Platform.environment['WINDIR'] ?? r'C:\Windows'}\\Fonts';
  final fonts = <String, List<String>>{
    sansFamily: ['NotoSansSC-VF.ttf', 'msyh.ttc'],
    serifFamily: ['NotoSerifSC-VF.ttf', 'simsun.ttc'],
    monoFamily: ['CascadiaMono.ttf', 'consola.ttf'],
  };
  for (final entry in fonts.entries) {
    for (final name in entry.value) {
      final file = File('$root\\$name');
      if (!file.existsSync()) continue;
      try {
        final bytes = await file.readAsBytes();
        await (FontLoader(
          entry.key,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        break;
      } catch (_) {
        // 字体文件损坏或被占用时尝试下一个候选。
      }
    }
  }
}
