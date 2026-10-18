/// 从文件名取书名和作者（V72，LIB-116）。
///
/// 先去掉末尾的下载重复编号（“ (1)”“ (2)”）。之后按设置：
/// * 自动识别（默认）：认 `《书名》（校对版全本）作者：某某`、`《书名》作者：某某`、`《书名》`、
///   `书名 作者：某某`、`书名_作者:某某`、`书名(作者)`、`书名（作者）`。
///   书名后带“校对、精校、全本、完结”等字样的括号说明去掉；括号里是“上、中、下、卷、册、番外”或数字时不当作者。
///   “书名 - 作者”这类没有标记的写法不猜。
/// * 自定义格式：`{书名}`、`{作者}`、`{*}`（任意内容，忽略）组成的格式，整个文件名必须符合；不符合时不提取。
/// * 不提取：书名用文件名，作者留空。
/// 关掉“书名里去掉作者名”时，书名保留（去掉重复编号后的）整个文件名，只另外填作者。
class FileNameMetadata {
  const FileNameMetadata(this.title, this.author);
  final String title;

  /// 认不出作者时为空字符串。
  final String author;
}

/// 全局设置里的提取方式（`filename_author_mode`、`filename_pattern`、`filename_strip_author`）。
class FileNameOptions {
  const FileNameOptions({
    this.mode = 'auto',
    this.pattern = defaultFileNamePattern,
    this.stripAuthor = true,
  });

  factory FileNameOptions.fromConfiguration(Map<String, dynamic> c) =>
      FileNameOptions(
        mode: switch (c['filename_author_mode']) {
          'custom' => 'custom',
          'off' => 'off',
          _ => 'auto',
        },
        pattern: (c['filename_pattern'] as String?)?.trim().isNotEmpty == true
            ? (c['filename_pattern'] as String).trim()
            : defaultFileNamePattern,
        stripAuthor: c['filename_strip_author'] != false,
      );

  final String mode, pattern;
  final bool stripAuthor;
}

const defaultFileNamePattern = '{书名}({作者})';

const fileNameAuthorModes = {'auto': '自动识别', 'custom': '自定义格式', 'off': '不提取'};

const _tagWords = [
  '校对', '精校', '全本', '完本', '完结', '全集', '修订', '精排', '文字版', //
  '未删', '典藏', '实体', '出版', 'txt', 'TXT', 'epub', 'EPUB',
];

final _authorMark = RegExp(r'作者\s*[:：]\s*');
final _bracketGroup = RegExp(r'\s*[（(\[【〔][^（）()\[\]【】〔〕]*[）)\]】〕]\s*$');
final _copySuffix = RegExp(r'\s+[(（]\d{1,3}[)）]$');
final _trailingAuthor = RegExp(r'^(.+?)\s*[(（]([^()（）]+)[)）]$');

/// 括号里是分册、卷次、数字时不是作者。
final _notAuthor = RegExp(
  r'^(上|中|下|上卷|中卷|下卷|全|续|番外|[卷册部集篇].*|.*[卷册部集篇]|[0-9０-９]+|[一二三四五六七八九十百千零〇两]+)$',
);

/// 去掉末尾带版本字样的括号说明（可连续多个）。
String _stripTags(String value) {
  var text = value.trim();
  while (true) {
    final m = _bracketGroup.firstMatch(text);
    if (m == null) return text;
    final group = m.group(0)!;
    if (!_tagWords.any(group.contains)) return text;
    text = text.substring(0, m.start).trim();
  }
}

/// 去掉作者后面的任何括号说明和分隔符。
String _cleanAuthor(String value) {
  var text = value.trim();
  final cut = RegExp(r'[（(\[【〔_]').firstMatch(text);
  if (cut != null) text = text.substring(0, cut.start);
  text = text.replaceAll(RegExp(r'\s*著$'), '').trim();
  return text.length > 30 ? '' : text;
}

String _stem(String fileName) {
  final name = fileName.replaceAll('\\', '/').split('/').last;
  var stem = name.replaceFirst(
    RegExp(r'\.(txt|epub)$', caseSensitive: false),
    '',
  );
  while (true) {
    final next = stem.replaceFirst(_copySuffix, '');
    if (next == stem || next.isEmpty) return stem;
    stem = next;
  }
}

FileNameMetadata _auto(String stem) {
  final quoted = RegExp(r'《([^《》]+)》').firstMatch(stem);
  final mark = _authorMark.firstMatch(stem);
  final author = mark == null ? '' : _cleanAuthor(stem.substring(mark.end));
  if (quoted != null && quoted.group(1)!.trim().isNotEmpty) {
    return FileNameMetadata(quoted.group(1)!.trim(), author);
  }
  if (mark != null && author.isNotEmpty) {
    final title = _stripTags(
      stem
          .substring(0, mark.start)
          .replaceAll('《》', '')
          .replaceAll(RegExp(r'[\s_\-—]+$'), ''),
    );
    if (title.isNotEmpty) return FileNameMetadata(title, author);
  }
  if (mark == null) {
    // 书名(作者)：括号里不是版本说明、分册或数字时当作者。
    final m = _trailingAuthor.firstMatch(stem);
    final inner = m?.group(2)!.trim() ?? '';
    if (m != null &&
        inner.isNotEmpty &&
        inner.length <= 20 &&
        !_tagWords.any(inner.contains) &&
        !_notAuthor.hasMatch(inner)) {
      final title = _stripTags(m.group(1)!);
      if (title.isNotEmpty) return FileNameMetadata(title, inner);
    }
  }
  final title = _stripTags(stem);
  return FileNameMetadata(title.isEmpty ? stem : title, '');
}

/// 自定义格式转成正则：占位符之外的文字按原样匹配。
RegExp? _patternRegExp(String pattern) {
  final buffer = StringBuffer('^');
  var hasTitle = false;
  final token = RegExp(r'\{(书名|作者|\*)\}');
  var last = 0;
  for (final m in token.allMatches(pattern)) {
    buffer.write(RegExp.escape(pattern.substring(last, m.start)));
    switch (m.group(1)) {
      case '书名':
        if (hasTitle) return null;
        hasTitle = true;
        buffer.write('(?<title>.+?)');
      case '作者':
        buffer.write('(?<author>.+?)');
      default:
        buffer.write('.*?');
    }
    last = m.end;
  }
  buffer.write(RegExp.escape(pattern.substring(last)));
  buffer.write(r'$');
  if (!hasTitle) return null;
  try {
    return RegExp(buffer.toString());
  } on FormatException {
    return null;
  }
}

/// 自定义格式是否可用（必须恰好有一个 {书名}，{作者} 最多一个）。
bool isValidFileNamePattern(String pattern) =>
    '{作者}'.allMatches(pattern).length <= 1 &&
    _patternRegExp(pattern.trim()) != null;

FileNameMetadata fileNameMetadata(
  String fileName, [
  FileNameOptions options = const FileNameOptions(),
]) {
  final stem = _stem(fileName);
  final found = switch (options.mode) {
    'off' => FileNameMetadata(stem, ''),
    'custom' => () {
      final re = isValidFileNamePattern(options.pattern)
          ? _patternRegExp(options.pattern.trim())
          : null;
      final m = re?.firstMatch(stem);
      if (m == null) return FileNameMetadata(stem, '');
      final title = m.namedGroup('title')!.trim();
      final author = m.groupNames.contains('author')
          ? m.namedGroup('author')!.trim()
          : '';
      return title.isEmpty
          ? FileNameMetadata(stem, '')
          : FileNameMetadata(title, author.length > 30 ? '' : author);
    }(),
    _ => _auto(stem),
  };
  return options.stripAuthor || found.author.isEmpty
      ? found
      : FileNameMetadata(stem, found.author);
}
