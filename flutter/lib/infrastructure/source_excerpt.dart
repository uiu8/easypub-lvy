import '../src/rust/api.dart' as api;

/// 原文若干行，每行“行号: 文字”并以换行结尾（桥接第 2 批：读有类型的行，不再拆文字）。
Future<String> sourceExcerpt({
  required String sourceId,
  required int revision,
  required int lineIndex,
  required int limit,
}) async {
  final page = await api.readSourceLines(
    sourceId: sourceId,
    revision: revision,
    lineIndex: lineIndex,
    utf8Column: 0,
    limit: limit,
  );
  return page.lines.map((line) => '${line.lineNumber}: ${line.text}\n').join();
}
