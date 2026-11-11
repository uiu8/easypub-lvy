import 'package:flutter/foundation.dart';

import 'manual_note_service.dart' show NoteLocation;

const inlineStyleFormatNotes = {
  'kfx_underline_fallback': 'KFX 使用普通下划线，当前转换器不支持波浪线。',
  'azw3_mobi_font_fallback': 'AZW3/MOBI 不保证保留此字体，可能使用阅读器默认字体。',
  'reader_font_required': '需要阅读器具备该字体并启用出版商字体；不嵌入字体。',
};

const inlineStyleReasons = {
  'inline_style_invalid': '样式数据无效。',
  'inline_style_empty': '请选择非空文字区间。',
  'inline_style_overlap': '样式不能交叉重叠，可以完整包含。',
  'inline_style_duplicate': '相同区间已经有此样式。',
  'inline_style_font_conflict': '同一段文字不能同时指定楷体与仿宋。',
  'inline_style_missing': '样式已不存在，请刷新。',
  'inline_style_stale': '书稿或设置已改变，请重新预览。',
  'line_changed': '原行文字或换行已改变，样式已停用。',
  'inline_style_range_out_of_bounds': '位置超出书稿范围。',
  'inline_style_character_boundary': '请选择同一行内的完整字符。',
  'inline_style_contains_heading': '暂不支持标题行样式。',
  'inline_style_markup_boundary': '请完整选择已有注音或着重号标记。',
  'inline_style_link_invalid': '网址要以 http://、https:// 或 mailto: 开头。',
};

class InlineStyleException implements Exception {
  const InlineStyleException(this.reason);
  final String reason;
  @override
  String toString() => inlineStyleReasons[reason] ?? '无法处理行内样式：$reason';
}

/// UTF-8 整行范围、行内区间、整行 SHA-256；使用 resolvePosition 获取。
class InlineStyleAnchor {
  InlineStyleAnchor.fromJson(Map v)
    : start = v['start'] as int,
      end = v['end'] as int,
      from = v['from'] as int,
      to = v['to'] as int,
      fingerprint = v['fingerprint'] as String;
  final int start, end, from, to;
  final String fingerprint;
  Map<String, Object> toJson() => {
    'start': start,
    'end': end,
    'from': from,
    'to': to,
    'fingerprint': fingerprint,
  };
}

class InlineStyleDraft {
  const InlineStyleDraft(this.anchor, this.style, {this.href});
  final InlineStyleAnchor anchor;

  /// bold / italic / em_dot / underline / wavy / kai / fang_song / sup / sub / link
  final String style;

  /// 只有 link 有。
  final String? href;
  Map<String, Object> toJson() => {
    'anchor': anchor.toJson(),
    'style': style,
    'href': ?href,
  };
}

class InlineStyleView {
  InlineStyleView.fromJson(Map v)
    : id = v['id'] as String,
      valid = v['valid'] as bool,
      reason = v['reason'] as String?,
      text = v['text'] as String,
      style = v['annotation']['style'] as String,
      href = v['annotation']['href'] as String?,
      source = v['source'] as bool? ?? false,
      formatNotes = List<String>.unmodifiable(
        (v['format_notes'] as List? ?? []).cast<String>(),
      ),
      anchor = InlineStyleAnchor.fromJson(v['annotation']['anchor'] as Map),
      location = v['location'] == null
          ? null
          : NoteLocation.fromJson(v['location'] as Map);
  final String id, text, style;
  final String? href;

  /// 导入时从原书读到的，不是手工加的。
  final bool source;
  final List<String> formatNotes;
  final bool valid;
  final String? reason;
  final InlineStyleAnchor anchor;
  final NoteLocation? location;
}

/// 原书表格的一格。
class SourceTableCell {
  SourceTableCell.fromJson(Map v)
    : text = v['text'] as String,
      head = v['head'] as bool,
      columns = v['columns'] as int;
  final String text;
  final bool head;
  final int columns;
}

/// 章节页只读显示的原书表格。
class SourceTableView {
  SourceTableView.fromJson(Map v)
    : id = v['id'] as String,
      removed = v['removed'] as bool,
      caption = v['caption'] as String,
      rows = [
        for (final row in (v['rows'] as List).cast<List>())
          [for (final cell in row.cast<Map>()) SourceTableCell.fromJson(cell)],
      ],
      location = v['location'] == null
          ? null
          : NoteLocation.fromJson(v['location'] as Map);
  final String id, caption;
  final bool removed;
  final List<List<SourceTableCell>> rows;
  final NoteLocation? location;
}

class InlineStyleSnapshot {
  InlineStyleSnapshot.fromJson(Map v)
    : contentId = v['content_id'] as String,
      items = List.unmodifiable(
        (v['items'] as List).cast<Map>().map(InlineStyleView.fromJson),
      ),
      tables = List.unmodifiable(
        (v['tables'] as List? ?? []).cast<Map>().map(SourceTableView.fromJson),
      ),
      invalidCount = v['invalid_count'] as int;
  final String contentId;
  final List<InlineStyleView> items;
  final List<SourceTableView> tables;
  final int invalidCount;
}

class InlineStylePreview {
  const InlineStylePreview(this.before, this.after);
  final InlineStyleSnapshot before, after;
}

abstract interface class InlineStyleLibrary {
  InlineStyleSession openInlineStyles(String bookId);
}

/// 已在书库的书从原文件补读行内样式。
abstract interface class SourceMarkLibrary {
  /// 读到的概要，含 path、sha256 和各类数量；没读到时没有 path。
  Future<Map<String, dynamic>> rereadSourceMarks(String bookId);
}

abstract interface class InlineStyleSession {
  Listenable get changes;
  Future<InlineStyleSnapshot> list();
  Future<InlineStyleAnchor> resolvePosition(
    InlineStyleSnapshot snapshot, {
    required String entryId,
    required int line,
    required int utf16Start,
    required int utf16End,
  });
  Future<InlineStylePreview> previewAdd(
    InlineStyleSnapshot snapshot,
    InlineStyleDraft draft,
  );

  /// 跨行选择拆成的逐行条目：全部通过才写入，记为一步、一次撤销。
  Future<InlineStylePreview> previewAddAll(
    InlineStyleSnapshot snapshot,
    List<InlineStyleDraft> drafts,
  );
  Future<InlineStylePreview> previewUpdate(
    InlineStyleSnapshot snapshot,
    String id,
    InlineStyleDraft draft,
  );
  Future<InlineStylePreview> previewDelete(String id);

  /// 移动本书共用的制作历史游标，包括其他制作修改。
  Future<InlineStylePreview> previewUndo();
  Future<InlineStylePreview> previewRedo();
  Future<void> confirm(InlineStylePreview preview);
  void dispose();
}

/// 导入结果里的一句话：读到了什么，什么没保留。
String sourceMarksSummary(Map<dynamic, dynamic> marks) {
  int count(String key) => (marks[key] as num? ?? 0).toInt();
  final parts = [
    if (count('styles') > 0) '${count('styles')} 处行内样式',
    if (count('links') > 0) '${count('links')} 个网址链接',
    if (count('tables') > 0) '${count('tables')} 张表格',
  ];
  return [
    if (parts.isNotEmpty) ' · 保留 ${parts.join('、')}',
    if (count('notes') > 0) ' · 识别 ${count('notes')} 个脚注标记（转换时仅保留同章脚注）',
    if (count('dropped_links') > 0) ' · ${count('dropped_links')} 个书内跳转链接未保留',
  ].join();
}

/// 导入报告里的原书标记换成书籍设置；没读到时为空。
Map<String, dynamic>? sourceMarkSelection(Map<String, dynamic>? report) {
  final marks = report?['source_marks'];
  if (marks is! Map || marks['path'] is! String) return null;
  int count(String key) => (marks[key] as num? ?? 0).toInt();
  return {
    'path': marks['path'],
    'sha256': marks['sha256'],
    'marks': count('styles') + count('links') + count('notes'),
    'tables': count('tables'),
  };
}
