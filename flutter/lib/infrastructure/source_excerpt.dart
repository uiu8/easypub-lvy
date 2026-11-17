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
  final text = StringBuffer();
  for (final line in page.lines) {
    text.write('${line.lineNumber}: ${line.text}');
    if (line.continues) text.write('〔本行过长，后续未展示〕');
    text.writeln();
  }
  if (page.nextLineIndex != null &&
      page.nextLineIndex! < lineIndex + limit &&
      !page.lines.any((line) => line.continues)) {
    text.writeln('〔摘录达到显示上限，后续未展示〕');
  }
  return text.toString();
}
