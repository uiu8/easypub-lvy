import 'dart:convert';

import 'package:flutter/foundation.dart';

const cleanupLabels = <String, String>{
  'trim_trailing_spaces': '行尾空白',
  'collapse_blank_lines': '合并连续空行',
  'remove_ad_lines': '广告与页眉候选',
  'remove_duplicate_titles': '连续重复标题',
  'normalize_width': '全角字母与数字',
  'normalize_punctuation': '兼容标点',
  'remove_invisible': '不可见字符',
  'ocr_han_spaces': 'OCR 汉字间空格',
  'ocr_ellipsis': 'OCR 省略号',
  'join_hard_wraps': '合并句中换行',
  'literal_replace': '文字替换',
  'regex_replace': '逐行正则替换',
  'multiline_regex_replace': '跨行正则替换',
  'chinese_variant': '简繁转换',
  'chapter_numbers': '章节编号样式',
  'chinese_punctuation': '中文标点',
  'notice_lines': '广告匹配与保留条件',
};

Map<String, dynamic> cleanupBase(Map<String, dynamic> step) =>
    step['kind'] == 'configured'
    ? (step['rule'] as Map).cast<String, dynamic>()
    : step;
String cleanupLabel(Map<String, dynamic> step) =>
    (step['kind'] == 'configured' ? step['name'] as String? : null) ??
    cleanupLabels[cleanupBase(step)['kind']] ??
    '自定义规则';

/// Serialized drafts keep mutable form maps out of pending plan identity.
class CleanupPreview {
  const CleanupPreview(
    this.request,
    this.guard,
    this.id,
    this.offset,
    this.total,
    this.candidateTotal,
    this.actions,
    this.candidates, {
    this.stages = const [],
    this.stageTotal = 0,
    this.stepCounts = const {},
  });
  final String request, guard, id;
  final int offset, total, candidateTotal;
  final List<CleanupChange> actions;
  final List<CleanupChange> stages;
  final int stageTotal;
  final Map<int, int> stepCounts;
  final List<CleanupCandidate> candidates;
}

class CleanupChange {
  const CleanupChange(
    this.line,
    this.end,
    this.step,
    this.before,
    this.after,
    this.reason,
    this.truncated,
  );
  final int line, end, step;
  final String before, reason;
  final String? after;
  final bool truncated;
}

class CleanupCandidate {
  const CleanupCandidate(
    this.line,
    this.text,
    this.selectable,
    this.selected,
    this.truncated,
  );
  final int line;
  final String text;
  final bool selectable, selected, truncated;
}

class CleanupReceipt {
  const CleanupReceipt(
    this.changes,
    this.candidates,
    this.chapterIssues, {
    this.editsKept = 0,
    this.editsDropped = 0,
  });
  final int changes, candidates, chapterIssues;

  /// 已换算到清理后文本的章节修改数，以及用户同意放弃的条数。
  final int editsKept, editsDropped;
}

/// 清理对已有章节修改与章节检查的影响。差异先显示，这部分在后台核对。
class CleanupImpact {
  const CleanupImpact({
    this.chapterIssues,
    this.edits = 0,
    this.skipped = const [],
    this.checkpoint = false,
  });

  /// 清理后有效稿的待核对问题数；章节修改无法换算时为 null。
  final int? chapterIssues;

  /// 本书现有的章节修改条数。
  final int edits;

  /// 无法换算到清理后文本的章节修改。
  final List<CleanupSkippedEdit> skipped;

  /// 章节修改已压缩为检查点：只保存了结果，没有可逐条换算的修改。
  final bool checkpoint;
}

class CleanupSkippedEdit {
  const CleanupSkippedEdit(this.index, this.action, this.reason);
  final int index;
  final String action, reason;
}

const cleanupCheckpointMessage =
    '这本书的章节修改经过多次压缩，原始操作不完整，无法逐条换算到清理后的文本。'
    '可在变更记录中撤销到压缩之前再清理，或先不清理。';

/// 撤销或重做清理时，有章节修改无法换算到新的文本（CLEAN-103）。不替用户决定：
/// 界面列出 [skipped]，用户确认放弃后调用 [proceed] 完成这一步。
class CleanupEditsNeedConfirmation implements Exception {
  const CleanupEditsNeedConfirmation({
    required this.redo,
    required this.kept,
    required this.skipped,
    required this.proceed,
  });

  /// true 为重做，false 为撤销。
  final bool redo;

  /// 能换算并保留的章节修改数。
  final int kept;
  final List<CleanupSkippedEdit> skipped;

  /// 放弃 [skipped] 并完成撤销或重做；书稿或清理历史已变化时报错，不会套用到别的状态。
  final Future<void> Function() proceed;

  @override
  String toString() =>
      '有 ${skipped.length} 处章节修改无法换算到${redo ? '重做' : '撤销'}后的文本，需要确认是否放弃。';
}

List<CleanupSkippedEdit> describeSkippedEdits(List skipped) => [
  for (final s in skipped.cast<Map>())
    CleanupSkippedEdit(
      s['index'] as int,
      describeEffectiveAction(s['action'] as Map),
      describeRebaseReason(s['reason'] as String),
    ),
];

/// 章节修改动作的简短说明（用于列出无法换算的条目）。
String describeEffectiveAction(Map action) {
  final title = action['title'] as String?;
  final named = title == null ? '' : '「$title」';
  return switch (action['kind']) {
    'rename' => '标题改为$named',
    'split' => '拆出新章节$named',
    'restore_heading' => '恢复标题$named',
    'insert_volume' || 'insert_source_volume' => '插入卷$named',
    'exclude_body_lines' => '删除正文行',
    'classify' => '更改标题身份',
    'create_boundary' || 'create_chapter_boundaries' => '新建章节',
    'merge_into' || 'merge_previous' || 'merge_subtree_previous' => '合并章节',
    'move' ||
    'move_subtree' ||
    'move_into_volume' ||
    'reorder' ||
    'reorder_source' => '调整章节顺序',
    'remove_duplicate_heading' || 'exclude_duplicate_chapter' => '移除重复标题',
    'recognize' => '按识别规则重新识别',
    _ => '章节修改',
  };
}

String describeRebaseReason(String reason) => switch (reason) {
  'line_changed' => '对应的行被清理删除或改动',
  'ids_diverged' => '新建的章节与清理前对不上',
  _ => '在清理后的文本上无法执行',
};

class CleanupInspection {
  const CleanupInspection(
    this.guard,
    this.compositionId,
    this.offset,
    this.changes,
    this.candidates,
    this.evidence, {
    this.findings = const [],
  });
  final String guard, compositionId;
  final int offset, changes, candidates;
  final List<String> evidence;
  final List<CleanupInspectionFinding> findings;
}

class CleanupInspectionFinding {
  const CleanupInspectionFinding(
    this.line,
    this.originalLine,
    this.kind,
    this.before,
    this.after,
    this.truncated,
    this.selectable,
  );
  final int line;
  final int? originalLine;
  final String kind, before;
  final String? after;
  final bool truncated, selectable;
}

abstract class CleanupContextSession {
  Future<String> previewSource(CleanupPreview preview, CleanupChange change);
}

abstract interface class PairedCleanupContextSession {
  Future<Map<String, dynamic>> pairedContext(
    CleanupPreview preview,
    CleanupChange change, {
    int offset = 0,
    int? regionLine,
    bool stage = false,
    int charOffset = 0,
  });
}

abstract class CleanupSession {
  Future<String> inspectionSource(
    CleanupInspection inspection,
    CleanupInspectionFinding finding,
  );
  Future<CleanupPreview> previewInspectionRemoval(
    CleanupInspection inspection,
    CleanupInspectionFinding finding,
  );
  Future<CleanupInspection> recheck({int offset = 0});
  bool isInspectionCurrent(CleanupInspection inspection);
  Listenable get changes;
  String get settings;
  bool get canUndo;
  bool get canRedo;
  bool isCurrent(CleanupPreview preview);
  Future<CleanupPreview> preview(String request, {int offset = 0});

  /// 核对清理对章节修改与检查的影响；结果随方案缓存。
  Future<CleanupImpact> impact(CleanupPreview preview);

  /// [dropSkipped] 为 true 表示用户已确认放弃无法换算的章节修改。
  Future<CleanupReceipt> apply(
    CleanupPreview preview, {
    bool dropSkipped = false,
  });
  Future<void> undo();
  Future<void> redo();
  Future<List<Map<String, dynamic>>> presets();
  void cancel();
  void dispose();
}

Map<String, dynamic> decodeCleanup(String request) =>
    (jsonDecode(request) as Map).cast<String, dynamic>();
