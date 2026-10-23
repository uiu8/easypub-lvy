class ChapterNode {
  const ChapterNode(
    this.id,
    this.title,
    this.role,
    this.depth,
    this.line,
    this.inToc,
  );
  final String id, title, role;
  final int depth, line;
  final bool inToc;
}

const chapterPrefixNode = ChapterNode(r'$prefix', '卷前正文', 'body', 0, 1, false);

class ChapterPage {
  const ChapterPage(
    this.nodes,
    this.total,
    this.offset,
    this.guard, {
    this.body,
    this.bodyNodeId,
    this.editBudget,
  });
  final List<ChapterNode> nodes;
  final int total, offset;
  final String guard;
  final ChapterEditBudget? editBudget;
  final ChapterBody? body;
  final String? bodyNodeId;
}

class ChapterBody {
  const ChapterBody(
    this.lines,
    this.offset,
    this.total,
    this.more, {
    this.rows = const [],
  });
  final List<String> lines;
  final List<ChapterBodyRow> rows;
  final int offset, total;
  final bool more;
}

class ChapterBodyRow {
  const ChapterBodyRow(
    this.text,
    this.lineOffset,
    this.selectable, {
    this.nextCharOffset,
    this.outputLine,
  });
  final String text;
  final int lineOffset;
  final bool selectable;
  final int? nextCharOffset;

  /// 这一行在成品文本里的行号；排版小预览按它放插图（R5-01）。
  final int? outputLine;
}

abstract interface class ChapterBodyContinuationSession {
  Future<ChapterBodyRow> bodyLine(
    ChapterPage page,
    String nodeId,
    int offset,
    int charOffset,
  );
}

sealed class ChapterEdit {
  const ChapterEdit();
}

class InsertChapterVolume extends ChapterEdit {
  const InsertChapterVolume(this.nodeId, this.title);
  final String nodeId, title;
}

class CreateChapterBoundary extends ChapterEdit {
  const CreateChapterBoundary(this.nodeId, this.lineOffset, {this.depth = 0});
  final String nodeId;
  final int lineOffset, depth;
}

class RemoveDuplicateChapterHeading extends ChapterEdit {
  const RemoveDuplicateChapterHeading(this.nodeId);
  final String nodeId;
}

class ExcludeChapterBodyLines extends ChapterEdit {
  const ExcludeChapterBodyLines(this.nodeId, this.firstOffset, this.lastOffset);
  final String nodeId;
  final int firstOffset, lastOffset;
}

class DemoteChapterHeading extends ChapterEdit {
  const DemoteChapterHeading(this.nodeId);
  final String nodeId;
}

class RenameChapter extends ChapterEdit {
  const RenameChapter(this.nodeId, this.title);
  final String nodeId, title;
}

class SplitChapter extends ChapterEdit {
  const SplitChapter(this.nodeId, this.lineOffset, this.title);
  final String nodeId, title;
  final int lineOffset;
}

class MergeChapter extends ChapterEdit {
  const MergeChapter(this.nodeId, this.targetId, {this.title});
  final String nodeId, targetId;
  final String? title;
}

class MoveChapter extends ChapterEdit {
  const MoveChapter(this.nodeId, this.beforeId);
  final String nodeId;
  final String? beforeId;
}

class MoveChapterIntoVolume extends ChapterEdit {
  const MoveChapterIntoVolume(
    this.nodeId,
    this.volumeId, {
    required this.atStart,
  });
  final String nodeId, volumeId;
  final bool atStart;
}

/// An opaque, session-bound candidate. Creating it does not change the draft.
class ChapterEditPreview {
  const ChapterEditPreview();
}

class ChapterStateChanged extends FormatException {
  const ChapterStateChanged(super.message);
}

/// 一次写入多项审阅结论（CHK-052），只用于当前编辑稿的检查结果。
abstract interface class BatchIssueReviewSession {
  Future<ChapterIssuePage> reviewIssues(
    ChapterIssuePage page,
    List<String> ids,
    String? decision,
  );
}

abstract class ChapterSession {
  Future<ChapterRepairOptions> repairs(ChapterPage page);
  Future<ChapterRepairPlan> previewRepairs(
    ChapterRepairOptions options,
    Set<String> selectedIds,
  );
  Future<ChapterIssuePage> issues(
    ChapterPage page,
    int offset, {
    bool effective = false,
  });
  Future<ChapterIssuePage> reviewIssue(
    ChapterIssuePage page,
    String id,
    String? decision,
  );
  Future<String> issueSource(ChapterIssuePage page, ChapterIssue issue);
  Future<ChapterPage> volumes(ChapterPage page, int offset, {String? volumeId});
  Future<ChapterEditPreview> preview(ChapterPage page, ChapterEdit edit);
  Future<ChapterPage> previewTree(ChapterEditPreview preview, int offset);
  Future<ChapterBody> previewBody(
    ChapterEditPreview preview,
    String nodeId,
    int offset,
  );
  Future<void> confirm(ChapterEditPreview preview);
  Future<void> undoConfirmed(ChapterEditPreview preview);
  bool get canUndo;
  bool get canRedo;
  Future<ChapterPage> read(
    int offset, {
    bool includeBody = false,
    String? preferredNodeId,
  });
  Future<ChapterBody> body(ChapterPage page, String nodeId, int offset);
  Future<void> rename(ChapterPage page, String nodeId, String title);
  Future<void> properties(
    ChapterPage page,
    ChapterNode node, {
    String? role,
    bool? inToc,
  });
  Future<void> history(ChapterPage page, {required bool undo});
}

abstract interface class FilteredChapterSession {
  Future<ChapterIssuePage> filteredIssues(
    ChapterPage page,
    int offset, {
    bool effective = false,
    String? category,
    String? severity,
  });
}

const chapterIssueCategories = <String, String>{
  'duplicate-content': '整章正文重复',
  'prose-heading': '正文被当成标题',
  'unrecognized-heading': '漏识别的标题',
  'duplicate-title': '重复标题',
  'number-reset': '编号回退或重复',
  'number-gap': '编号跳跃',
  'no-headings': '未识别标题',
  'missing-heading-prefix': '缺少章节前缀',
  'heading-number-typo': '章节编号疑误',
};
const chapterIssueSeverities = <String, String>{
  'error': '错误',
  'warning': '提醒',
  'info': '提示',
};

class ChapterIssueContext {
  const ChapterIssueContext({
    this.effectiveText,
    this.originalText,
    this.originalLine,
    this.rows = const [],
    this.originalRows = const [],
    this.compositionId,
  });
  final String? effectiveText, originalText;
  final int? originalLine;
  final List<ChapterContextRow> rows, originalRows;
  final String? compositionId;
}

/// A version-bound paragraph. Source coordinates may be absent for new text.
class ChapterContextRow {
  const ChapterContextRow(
    this.text, {
    this.line,
    this.originalLine,
    this.anchor,
    this.truncated = false,
  });
  final String text;
  final int? line, originalLine;
  final String? anchor;
  final bool truncated;
}

abstract interface class ChapterIssueContextSession {
  Future<ChapterIssueContext> issueContext(
    ChapterIssuePage page,
    ChapterIssue issue, {
    int anchor = 0,
  });
}

class ChapterIssue {
  const ChapterIssue(
    this.id,
    this.category,
    this.title,
    this.evidence,
    this.lines,
    this.decision,
    this.categoryReviewed,
    this.autoApplicable, {
    this.entryId,
    this.nodeOffset,
    this.severity = 'info',
    this.subtype,
    this.originalLines = const [],
    this.anchors = const [],
    this.hasSuggestion = false,
    this.bodyOffset = 0,
    this.focusLine,
  });
  String get categoryLabel => switch (subtype) {
    'repeated-number' => '编号重复',
    'number-reversal' => '编号回退',
    _ => chapterIssueCategories[category] ?? '章节结构',
  };

  final List<ChapterIssueAnchor> anchors;
  final bool hasSuggestion;
  final int bodyOffset;
  final int? focusLine;
  ChapterIssue atAnchor(int index) {
    if (index >= anchors.length) return this;
    final a = anchors[index];
    return ChapterIssue(
      id,
      category,
      title,
      evidence,
      lines,
      decision,
      categoryReviewed,
      autoApplicable,
      entryId: a.entryId,
      nodeOffset: a.nodeOffset,
      severity: severity,
      subtype: subtype,
      originalLines: originalLines,
      anchors: anchors,
      hasSuggestion: hasSuggestion,
      bodyOffset: a.bodyOffset,
      focusLine: a.line,
    );
  }

  final String id, category, title, evidence;
  final List<int> lines;
  final String? decision;
  final bool categoryReviewed, autoApplicable;
  final List<int?> originalLines;
  final String severity;
  final String? subtype;
  final String? entryId;
  final int? nodeOffset;
}

class ChapterIssueAnchor {
  const ChapterIssueAnchor(
    this.title,
    this.line,
    this.entryId,
    this.nodeOffset,
    this.bodyOffset,
    this.originalLine, {
    this.startLine,
    this.endLine,
  });
  final String title, entryId;
  final int line, nodeOffset, bodyOffset;
  final int? originalLine;
  final int? startLine, endLine;
}

class ChapterIssuePage {
  const ChapterIssuePage(
    this.items,
    this.total,
    this.offset, {
    this.effective = false,
    this.categoryCounts = const {},
    this.severityCounts = const {},
    this.categoryFilter,
    this.severityFilter,
    this.filteredCategoryCounts = const {},
    this.reviewed,
    this.unfilteredTotal,
  });
  final Map<String, int> categoryCounts, severityCounts;

  /// 当前筛选结果中各类别的数量；结果按 [chapterIssueGroupOf] 分组排序（CHK-053）。
  final Map<String, int> filteredCategoryCounts;

  /// 已有审阅结论的项数与未筛选总数（顶部进度）；旧接口为 null。
  final int? reviewed, unfilteredTotal;
  final String? categoryFilter, severityFilter;
  final List<ChapterIssue> items;
  final int total, offset;
  final bool effective;
}

/// 问题分组（与 Rust `review::issue_group` 一致）：认全 → 去重 → 归位。
const chapterIssueGroups = <(String, String)>[
  ('认全', '漏识别与缺章'),
  ('去重', '重复的章节与标题'),
  ('归位', '编号、层级与误收的标题'),
];

int chapterIssueGroupOf(String category) => switch (category) {
  'unrecognized-heading' ||
  'number-gap' ||
  'heading-number-typo' ||
  'no-headings' => 0,
  'duplicate-content' || 'duplicate-title' => 1,
  _ => 2,
};

/// 一个结构节点上的问题汇总；[severity] 取未处理问题中最重的一级（全部已审阅时取全部）。
class ChapterIssueMark {
  const ChapterIssueMark(
    this.entryId,
    this.severity,
    this.count,
    this.open, {
    this.index,
  });
  final String entryId, severity;
  final int count, open;

  /// 在全书结构中的序号；卷前正文为 null。
  final int? index;
}

/// 全书问题位置（当前编辑稿的章节结构检查）。[marks] 只含有问题的节点；
/// [chapterIssues] 是请求的那一章内或触及该章的问题（最多 200 条）。
class ChapterIssueMap {
  const ChapterIssueMap({
    required this.guard,
    required this.evidenceId,
    required this.total,
    required this.open,
    this.openSeverities = const {},
    this.marks = const {},
    this.chapterId,
    this.chapterIssues = const [],
    this.chapterTotal = 0,
    this.reviewIndex = const {},
  });
  final String guard, evidenceId;
  final int total, open;
  final Map<String, int> openSeverities;
  final Map<String, ChapterIssueMark> marks;
  final String? chapterId;
  final List<ChapterIssue> chapterIssues;
  final int chapterTotal;

  /// 问题在未筛选报告中的序号，用于在问题浏览器中翻到它所在的页。
  final Map<String, int> reviewIndex;
}

/// 问题位置汇总：[summary] 为 true 时返回全书按节点汇总；[entryId] 指定章节时返回该章问题。
abstract interface class ChapterIssueMapSession {
  Future<ChapterIssueMap> issueMap(
    ChapterPage page, {
    bool summary = true,
    String? entryId,
  });
}

class ChapterRepairChange {
  const ChapterRepairChange(
    this.id,
    this.entryId,
    this.title,
    this.line,
    this.keptLine,
    this.before,
    this.after,
    this.truncated, {
    this.recommended = true,
    this.requires = const [],
  });
  final String id, entryId, title, before, after;
  final int line, keptLine;
  final bool truncated;
  final bool recommended;
  final List<String> requires;
}

class ChapterRepairOptions {
  const ChapterRepairOptions(this.changes, this.total, this.report);
  final List<ChapterRepairChange> changes;
  final int total;
  final ChapterIssuePage report;
}

/// 修复方案的实际影响：分别对当前编辑稿和候选编辑稿运行同一检查得到，不是估算。
class ChapterRepairImpact {
  const ChapterRepairImpact({
    required this.nodesBefore,
    required this.nodesAfter,
    required this.openBefore,
    required this.openAfter,
  });
  final int nodesBefore, nodesAfter, openBefore, openAfter;

  /// 应用后待处理问题减少的数量；新增问题时为负数。
  int get resolved => openBefore - openAfter;
}

/// 可选能力：对已生成的修复方案计算目录节点与待处理问题的前后数量。
abstract interface class ChapterRepairImpactSession {
  Future<ChapterRepairImpact> repairImpact(ChapterRepairPlan plan);
}

class ChapterRepairPlan {
  const ChapterRepairPlan(this.preview, this.changes);
  final ChapterEditPreview preview;
  final List<ChapterRepairChange> changes;
}

class ChapterComparisonSide {
  const ChapterComparisonSide({
    required this.title,
    required this.rows,
    required this.nodes,
    required this.offset,
    required this.totalRows,
    this.focusLine,
    this.nextOffset,
    this.nextCharOffset = 0,
  });
  final String title;
  final List<ChapterContextRow> rows;
  final List<ChapterNode> nodes;
  final int offset, totalRows;
  final int? focusLine;
  final int? nextOffset;
  final int nextCharOffset;
}

class ChapterRepairComparison {
  const ChapterRepairComparison(
    this.before,
    this.after, {
    this.retainedCopy = false,
  });
  final ChapterComparisonSide before, after;
  final bool retainedCopy;
}

abstract interface class ChapterRepairComparisonSession {
  Future<ChapterRepairComparison> previewComparison(
    ChapterRepairPlan plan,
    ChapterRepairChange change, {
    int beforeOffset = 0,
    int afterOffset = 0,
    int beforeCharOffset = 0,
    int afterCharOffset = 0,
  });
}

abstract interface class ChapterCheckpointSession {
  int get pendingEditActions;
  Future<ChapterEditPreview> previewCheckpoint(ChapterPage page);
}

class ChapterEditBudget {
  const ChapterEditBudget(
    this.replayBytes,
    this.nextActionBytes,
    this.limitBytes,
  );
  final int replayBytes, nextActionBytes, limitBytes;
  bool get canAppend => replayBytes + nextActionBytes <= limitBytes;
  bool get nearLimit =>
      replayBytes > 0 && (replayBytes >= limitBytes * 0.8 || !canAppend);
}

/// A compact full outline, without manuscript body, for navigation and search.
abstract interface class ChapterOutlineSession {
  Future<ChapterPage> readOutline();
}

const maxChapterOutlineNodes = 30000;

abstract interface class TargetedChapterRepairSession {
  Future<ChapterRepairOptions> repairsForIssue(
    ChapterPage page,
    String issueId,
  );
}

class ChapterCopyReceipt {
  const ChapterCopyReceipt(
    this.textPath,
    this.projectPath,
    this.remainingIssues,
  );
  final String textPath, projectPath;
  final int remainingIssues;
}

abstract interface class ChapterCopySession {
  Future<ChapterEditPreview> previewCurrentCopy(ChapterPage page);
  Future<ChapterCopyReceipt> exportCopy(
    ChapterEditPreview preview,
    String outputPath,
  );
}
