import 'package:flutter/foundation.dart';

enum BlockAnnotationKind { letter, quote, verse, system, none }

const blockAnnotationLabels = {
  BlockAnnotationKind.letter: '书信',
  BlockAnnotationKind.quote: '引文',
  BlockAnnotationKind.verse: '诗词',
  BlockAnnotationKind.system: '系统提示',
  BlockAnnotationKind.none: '取消标注',
};
const blockAnnotationReasons = {
  'block_annotation_invalid': '标注数据无效，请重新选择连续正文行。',
  'block_annotation_overlap': '与已有标注重叠，请先修改或删除已有标注（包括失效项）。',
  'block_annotation_missing': '这条标注已不存在，请刷新列表。',
  'block_annotation_stale': '书稿或标注已改变，请刷新并重新预览。',
  'block_range_out_of_bounds': '原位置已超出书稿范围，请重新标注或删除。',
  'block_line_boundary_changed': '原位置不再对齐整行，请重新标注或删除。',
  'block_text_changed': '原位置的文字已改变，请重新标注或删除。',
  'block_contains_heading': '所选范围包含标题，请只选择正文行。',
  'block_crosses_section': '标注不能跨越正文分节，请分开标注。',
};

class BlockAnnotationException implements Exception {
  const BlockAnnotationException(this.reason);
  final String reason;
  String get message => blockAnnotationReasons[reason] ?? '无法处理标注，请检查书稿和制作资源。';
  @override
  String toString() => message;
}

class BlockAnnotationView {
  BlockAnnotationView.fromJson(Map value)
    : id = value['annotation']['id'] as String,
      start = value['annotation']['start'] as int,
      end = value['annotation']['end'] as int,
      kind = BlockAnnotationKind.values.byName(
        value['annotation']['kind'] as String,
      ),
      variant = value['annotation']['variant'] as String?,
      valid = value['valid'] as bool,
      reason = value['reason'] as String?,
      excerpt = value['excerpt'] as String,
      entryId = (value['location'] as Map?)?['entry_id'] as String?,
      firstLine = (value['location'] as Map?)?['first_line'] as int?,
      lastLine = (value['location'] as Map?)?['last_line'] as int?;
  final String id, excerpt;

  /// 有效标注在章节页的位置（V53）：分节 ID（卷前正文为 `$prefix`）与本节正文行号，
  /// 与 [ChapterBodyRow.lineOffset] 同一编号，从 1 开始、两端包含；失效项为空。
  final String? entryId;
  final int? firstLine, lastLine;

  /// 当前有效书稿的 UTF-8 字节半开区间，含末行换行；不是 Dart UTF-16 下标。
  final int start, end;
  final BlockAnnotationKind kind;

  /// 系统提示指定的样式（V78）：note 单行提示、panel 面板；null 按行数。
  final String? variant;
  final bool valid;
  final String? reason;
  String? get reasonText =>
      reason == null ? null : blockAnnotationReasons[reason];
}

class BlockAnnotationSnapshot {
  BlockAnnotationSnapshot.fromJson(Map value)
    : contentId = value['content_id'] as String,
      byteLength = value['byte_length'] as int,
      annotations = List.unmodifiable(
        (value['annotations'] as List).cast<Map>().map(
          BlockAnnotationView.fromJson,
        ),
      );
  final String contentId;
  final int byteLength;
  final List<BlockAnnotationView> annotations;
  List<BlockAnnotationView> get invalidAnnotations =>
      List.unmodifiable(annotations.where((a) => !a.valid));
}

class BlockAnnotationPreview {
  const BlockAnnotationPreview(this.before, this.after);
  final BlockAnnotationSnapshot before, after;
}

class BlockAnnotationRange {
  const BlockAnnotationRange(this.start, this.end);
  final int start, end;
}

/// 能为一本书打开标注会话的书库（V53）；章节页据此决定是否显示手工标注。
abstract interface class BlockAnnotationLibrary {
  BlockAnnotationSession openBlockAnnotations(String bookId);
}

/// 每个实例绑定一本书。预览不修改书稿；所有写入必须显式 confirm。
abstract interface class BlockAnnotationSession {
  Listenable get changes;
  Future<BlockAnnotationSnapshot> list();

  /// 使用 ChapterBodyRow.lineOffset；起止行均包含在内，不接收截断的显示文字。
  Future<BlockAnnotationRange> resolveLines(
    BlockAnnotationSnapshot snapshot, {
    required String entryId,
    required int firstLine,
    required int lastLine,
  });
  Future<BlockAnnotationPreview> previewAdd(
    BlockAnnotationSnapshot snapshot, {
    required int start,
    required int end,
    required BlockAnnotationKind kind,
    String? variant,
  });
  Future<BlockAnnotationPreview> previewUpdate(
    BlockAnnotationSnapshot snapshot,
    String id, {
    required int start,
    required int end,
    required BlockAnnotationKind kind,
    String? variant,
  });
  Future<BlockAnnotationPreview> previewDelete(String id);

  /// 与“制作”变更记录共用历史；撤销/重做最后一次本书制作修改。
  Future<BlockAnnotationPreview> previewUndo();
  Future<BlockAnnotationPreview> previewRedo();
  Future<void> confirm(BlockAnnotationPreview preview);
  void dispose();
}
