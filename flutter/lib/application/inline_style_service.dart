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
  const InlineStyleDraft(this.anchor, this.style);
  final InlineStyleAnchor anchor;

  /// bold / italic / em_dot / underline / wavy / kai / fang_song
  final String style;
  Map<String, Object> toJson() => {'anchor': anchor.toJson(), 'style': style};
}

class InlineStyleView {
  InlineStyleView.fromJson(Map v)
    : id = v['id'] as String,
      valid = v['valid'] as bool,
      reason = v['reason'] as String?,
      text = v['text'] as String,
      style = v['annotation']['style'] as String,
      formatNotes = List<String>.unmodifiable(
        (v['format_notes'] as List? ?? []).cast<String>(),
      ),
      anchor = InlineStyleAnchor.fromJson(v['annotation']['anchor'] as Map),
      location = v['location'] == null
          ? null
          : NoteLocation.fromJson(v['location'] as Map);
  final String id, text, style;
  final List<String> formatNotes;
  final bool valid;
  final String? reason;
  final InlineStyleAnchor anchor;
  final NoteLocation? location;
}

class InlineStyleSnapshot {
  InlineStyleSnapshot.fromJson(Map v)
    : contentId = v['content_id'] as String,
      items = List.unmodifiable(
        (v['items'] as List).cast<Map>().map(InlineStyleView.fromJson),
      ),
      invalidCount = v['invalid_count'] as int;
  final String contentId;
  final List<InlineStyleView> items;
  final int invalidCount;
}

class InlineStylePreview {
  const InlineStylePreview(this.before, this.after);
  final InlineStyleSnapshot before, after;
}

abstract interface class InlineStyleLibrary {
  InlineStyleSession openInlineStyles(String bookId);
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
