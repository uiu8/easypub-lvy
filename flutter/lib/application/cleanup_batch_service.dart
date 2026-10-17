import 'cleanup_service.dart';

import 'package:flutter/foundation.dart';

class CleanupBatchItem {
  const CleanupBatchItem(
    this.bookId,
    this.changes,
    this.candidates,
    this.error,
    this.samples, {
    this.editsKept = 0,
    this.skippedEdits = const [],
  });
  final String bookId, error;
  final int changes, candidates;
  final List<String> samples;

  /// 这本书能换算到清理后文本并保留的章节修改数（CLEAN-104）。
  final int editsKept;

  /// 无法换算的章节修改；不为空时须由用户决定放弃这些修改，或不清理这本书。
  final List<CleanupSkippedEdit> skippedEdits;
  bool get needsDecision => error.isEmpty && skippedEdits.isNotEmpty;
}

class CleanupBatchPreview {
  const CleanupBatchPreview(this.items);
  final List<CleanupBatchItem> items;
  bool get ready =>
      items.isNotEmpty && items.every((item) => item.error.isEmpty);
}

abstract class CleanupBatchSession {
  Listenable get changes;
  bool canRead(CleanupBatchPreview plan, String bookId);
  Future<CleanupBatchPreview> preview(
    String template,
    List<String> targets, {
    required bool append,
  });
  bool isCurrent(CleanupBatchPreview plan);
  Future<CleanupBatchDifferencePage> differences(
    CleanupBatchPreview plan,
    String bookId, {
    int offset = 0,
  });

  /// [dropEdits] 是用户确认放弃无法换算的章节修改的书；有无法换算修改的书
  /// 不在其中时不采用整批，不替用户决定。
  Future<void> apply(
    CleanupBatchPreview plan, {
    Set<String> dropEdits = const {},
  });
  void cancel();
  void dispose();
}

class CleanupBatchDifferencePage {
  const CleanupBatchDifferencePage(
    this.offset,
    this.total,
    this.candidateTotal,
    this.actions,
    this.candidates,
  );
  final int offset, total, candidateTotal;
  final List<CleanupChange> actions;
  final List<CleanupCandidate> candidates;
}
