import 'package:flutter/foundation.dart';

enum ManualNoteKind { automatic, pair, newNote }

const manualNoteReasons = {
  'note_invalid': '注释数据无效，请重新选择位置。',
  'note_overlap': '标记与已有注释重叠，请修改或删除已有注释。',
  'note_definition_used': '注释行已被占用，或同时被用作正文标记。',
  'note_missing': '这条注释已不存在，请刷新列表。',
  'note_stale': '书稿或制作设置已改变，请刷新并重新预览。',
  'note_range_out_of_bounds': '原位置已超出书稿，请重新选择。',
  'note_line_boundary_changed': '原位置不再对齐完整行或字符，请重新选择。',
  'note_text_changed': '原位置的文字或换行已改变，请重新标注。',
  'note_contains_heading': '不能将标题用作注释标记或注释行。',
  'note_crosses_chapter': '正文标记与注释行必须在同一章。',
  'note_character_boundary': '位置超出本行或切开了一个字符，请重新选择。',
  'note_text_invalid': '注释文字不能为空，最多 2 万字，请使用纯文本。',
};

class ManualNoteException implements Exception {
  const ManualNoteException(this.reason);
  final String reason;
  String get message => manualNoteReasons[reason] ?? '无法处理注释，请检查书稿与制作设置。';
  @override
  String toString() => message;
}

/// 当前有效稿整行字节范围与行内 UTF-8 字节偏移；使用 resolvePosition 获取。
class NoteSelection {
  const NoteSelection(this.start, this.end, this.from, this.to);
  NoteSelection.fromJson(Map v)
    : this(
        v['start'] as int,
        v['end'] as int,
        v['from'] as int,
        v['to'] as int,
      );
  final int start, end, from, to;
  Map<String, Object> toJson() => {
    'start': start,
    'end': end,
    'from': from,
    'to': to,
  };
  NoteSelection get wholeLine => NoteSelection(start, end, 0, 0);
}

class NoteLocation {
  NoteLocation.fromJson(Map v)
    : entryId = v['entry_id'] as String,
      line = v['first_line'] as int,
      utf16Start = v['utf16_start'] as int,
      utf16End = v['utf16_end'] as int;
  final String entryId;

  /// 章节正文行号从 1 开始，字符偏移为 Dart UTF-16 半开区间。
  final int line, utf16Start, utf16End;
}

class ManualNoteDraft {
  const ManualNoteDraft.pair(this.reference, this.definition) : text = null;
  const ManualNoteDraft.newText(this.reference, this.text) : definition = null;
  final NoteSelection reference;
  final NoteSelection? definition;
  final String? text;
  Map<String, Object?> toJson() => {
    'kind': definition == null ? 'new' : 'pair',
    'reference': reference.toJson(),
    if (definition != null) 'definition': definition!.wholeLine.toJson(),
    if (text != null) 'text': text,
  };
}

class ManualNoteView {
  ManualNoteView.fromJson(Map v)
    : id = v['id'] as String,
      kind = switch (v['kind']) {
        'pair' => ManualNoteKind.pair,
        'new' => ManualNoteKind.newNote,
        _ => ManualNoteKind.automatic,
      },
      valid = v['valid'] as bool,
      enabled = v['enabled'] as bool,
      reason = v['reason'] as String?,
      marker = v['marker'] as String,
      text = v['text'] as String,
      location = v['location'] == null
          ? null
          : NoteLocation.fromJson(v['location'] as Map),
      definitionLocation = v['definition_location'] == null
          ? null
          : NoteLocation.fromJson(v['definition_location'] as Map),
      reference = v['note'] == null
          ? null
          : NoteSelection.fromJson(v['note']['reference'] as Map),
      definition = v['note']?['body']?['definition'] == null
          ? null
          : NoteSelection.fromJson(v['note']['body']['definition'] as Map);
  final String id, marker, text;
  final ManualNoteKind kind;
  final bool valid, enabled;
  final String? reason;
  final NoteLocation? location, definitionLocation;
  final NoteSelection? reference, definition;
  String? get reasonText => manualNoteReasons[reason];
}

class ManualNoteSnapshot {
  ManualNoteSnapshot.fromJson(Map v)
    : contentId = v['content_id'] as String,
      notes = List.unmodifiable(
        (v['notes'] as List).cast<Map>().map(ManualNoteView.fromJson),
      );
  final String contentId;
  final List<ManualNoteView> notes;
}

class ManualNotePreview {
  const ManualNotePreview(this.before, this.after);
  final ManualNoteSnapshot before, after;
}

abstract interface class ManualNoteLibrary {
  ManualNoteSession openManualNotes(String bookId);
}

abstract interface class ManualNoteSession {
  Listenable get changes;
  Future<ManualNoteSnapshot> list();
  Future<NoteSelection> resolvePosition(
    ManualNoteSnapshot snapshot, {
    required String entryId,
    required int line,
    required int utf16Start,
    required int utf16End,
  });
  Future<ManualNotePreview> previewAdd(
    ManualNoteSnapshot snapshot,
    ManualNoteDraft draft,
  );
  Future<ManualNotePreview> previewUpdate(
    ManualNoteSnapshot snapshot,
    String id,
    ManualNoteDraft draft,
  );
  Future<ManualNotePreview> previewDelete(String id);

  /// 移动本书共用的制作历史游标，包括其他制作修改。
  Future<ManualNotePreview> previewUndo();
  Future<ManualNotePreview> previewRedo();
  Future<void> confirm(ManualNotePreview preview);
  void dispose();
}
