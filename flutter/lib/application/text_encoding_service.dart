// TXT 的编码：解不开时让用户选，已导入的书能换。
import 'package:flutter/foundation.dart';

import 'source_refresh_service.dart';

/// 一种编码试解的结果。
class EncodingChoice {
  EncodingChoice.fromJson(Map v)
    : label = v['label'] as String,
      name = v['name'] as String,
      ok = v['ok'] as bool,
      lines = List<String>.unmodifiable((v['lines'] as List).cast<String>());
  final String label, name;
  final bool ok;

  /// 解出来的前 30 行。
  final List<String> lines;
}

class EncodingProbe {
  EncodingProbe.fromJson(Map v)
    : auto = v['auto'] as String?,
      suspect = v['suspect'] as bool,
      suggested = v['suggested'] as String?,
      candidates = List.unmodifiable(
        (v['candidates'] as List).cast<Map>().map(EncodingChoice.fromJson),
      );

  /// 自动判断的编码；解不开时为空。
  final String? auto;
  final bool suspect;

  /// 窗口里先选中哪一种。
  final String? suggested;
  final List<EncodingChoice> candidates;
}

abstract interface class TextEncodingService {
  /// 解不开、等用户选编码的文件。
  ValueListenable<List<String>> get undecodedFiles;

  /// 后台导入待处理项，只在书库显示，由用户主动选择。
  ValueListenable<List<String>> get pendingEncodingFiles;
  void dropUndecoded(String path);
  Future<EncodingProbe> probeEncoding(String path);

  /// 按选定的编码导入。
  Future<bool> importWithEncoding(String path, String encoding);

  /// 书里已经有用户的修改，换编码会让它们失效。
  bool hasEdits(String bookId);

  /// 按选定的编码重读原文件，还没换。选的就是现在的编码时，只去掉“可能不对”的
  /// 提示，返回空。
  Future<SourceRefreshPreview?> previewEncodingChange(
    String bookId,
    String encoding,
  );
}
