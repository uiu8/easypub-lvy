import 'chapter_service.dart';

import 'package:flutter/foundation.dart';

class CheckFinding {
  const CheckFinding(
    this.id,
    this.title,
    this.detail,
    this.target, {
    this.severity = 'warning',
  });
  final String id, title, detail, target, severity;
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'detail': detail,
    'target': target,
    'severity': severity,
  };
  factory CheckFinding.fromJson(Map value) => CheckFinding(
    value['id'] as String,
    value['title'] as String,
    value['detail'] as String,
    value['target'] as String,
    severity: value['severity'] as String? ?? 'warning',
  );
}

/// 文本清理检测的一条结果：结构化保存，供检查页按规则分组显示。
class CleanupCheckItem {
  const CleanupCheckItem(
    this.line,
    this.kind,
    this.before,
    this.after, {
    this.truncated = false,
    this.candidate = false,
  });
  final int line;
  final String kind, before;

  /// 修改后的文字；为 null 表示删除此行（广告候选也为 null）。
  final String? after;
  final bool truncated, candidate;

  Map<String, Object?> toJson() => {
    'line': line,
    'kind': kind,
    'before': before,
    'after': after,
    'truncated': truncated,
    'candidate': candidate,
  };

  factory CleanupCheckItem.fromJson(Map v) => CleanupCheckItem(
    v['line'] as int,
    v['kind'] as String,
    v['before'] as String,
    v['after'] as String?,
    truncated: v['truncated'] == true,
    candidate: v['candidate'] == true,
  );
}

class CheckDomain {
  const CheckDomain(
    this.id,
    this.title,
    this.status,
    this.detail,
    this.items, {
    this.failed = false,
    this.findings = const [],
    this.cleanup = const [],
    this.count,
  });
  final String id, title, status, detail;
  final List<String> items;
  final bool failed;

  /// 待处理的项数（章节问题、清理建议与候选、待补充字段）；旧报告没有时为 null。
  final int? count;
  final List<CheckFinding> findings;
  final List<CleanupCheckItem> cleanup;
}

/// 检查报告的格式版本。报告格式改变时加一；低于它的报告
/// 需要重新检查才能按当前方式显示。
const checkReportSchema = 1;

class BookCheckReport {
  const BookCheckReport(
    this.guard,
    this.domains,
    this.firstIssue,
    this.evidence,
    this.safeRepairs, {
    this.checkedAt,
    this.schema = checkReportSchema,
    this.bookId = '',
    this.guards = const {},
    this.baseline = const {},
  });
  final String guard;

  /// 每一项（chapters / cleanup / metadata / resources）算的是哪一版。
  /// 只重算对不上的项；旧报告没有时全部重算。
  final Map<String, String> guards;

  /// 从上次手动检查以来，每一项出现过的最大问题数。减去还没处理的就是做完的，
  /// 问题解决后从结果里消失，进度也不会倒退。
  final Map<String, int> baseline;

  /// 报告的格式版本；没有版本号的旧报告读取时归类一次，见 [BookCheckReport.fromJson]。
  final int schema;

  /// 书的标识（后来写入），用于按书回收缓存；更早的报告为空。
  final String bookId;

  /// 需要重新检查才能按当前方式显示。
  bool get outdated => schema < checkReportSchema;

  /// 检查完成的时间；旧报告没有记录时为 null。
  final DateTime? checkedAt;
  final List<CheckDomain> domains;
  final ChapterIssue? firstIssue;
  final String evidence;
  final int safeRepairs;
  Map<String, dynamic> toJson() => {
    'schema': schema,
    if (bookId.isNotEmpty) 'book_id': bookId,
    'guard': guard,
    if (guards.isNotEmpty) 'guards': guards,
    if (baseline.isNotEmpty) 'baseline': baseline,
    'evidence': evidence,
    'safe': safeRepairs,
    if (checkedAt != null) 'checked_at': checkedAt!.toIso8601String(),
    'domains': [
      for (final d in domains)
        {
          'id': d.id,
          'title': d.title,
          'status': d.status,
          'detail': d.detail,
          'items': d.items,
          'failed': d.failed,
          'findings': d.findings.map((f) => f.toJson()).toList(),
          'cleanup': d.cleanup.map((f) => f.toJson()).toList(),
          if (d.count != null) 'count': d.count,
        },
    ],
    'first': firstIssue == null
        ? null
        : {
            'id': firstIssue!.id,
            'category': firstIssue!.category,
            'title': firstIssue!.title,
            'evidence': firstIssue!.evidence,
            'lines': firstIssue!.lines,
            'decision': firstIssue!.decision,
            'reviewed': firstIssue!.categoryReviewed,
            'auto': firstIssue!.autoApplicable,
            'entry': firstIssue!.entryId,
            'offset': firstIssue!.nodeOffset,
          },
  };
  factory BookCheckReport.fromJson(Map value) {
    final f = value['first'] as Map?;
    final checkedAt = DateTime.tryParse(value['checked_at'] as String? ?? '');
    final domains = [
      for (final d in value['domains'] as List)
        CheckDomain(
          d['id'],
          d['title'],
          d['status'],
          d['detail'],
          (d['items'] as List).cast<String>(),
          failed: d['failed'] == true,
          findings: [
            for (final f in d['findings'] as List? ?? const [])
              CheckFinding.fromJson(f as Map),
          ],
          cleanup: [
            for (final f in d['cleanup'] as List? ?? const [])
              CleanupCheckItem.fromJson(f as Map),
          ],
          count: d['count'] as int?,
        ),
    ];
    // 早先的报告没有版本号：只在这里按早先的规则归类一次。没有检查时间，
    // 或文本清理只有文字清单（前）的为 0，其余为 1。
    final schema =
        value['schema'] as int? ??
        (checkedAt == null ||
                domains.any(
                  (d) =>
                      d.id == 'cleanup' &&
                      d.items.isNotEmpty &&
                      d.cleanup.isEmpty,
                )
            ? 0
            : 1);
    return BookCheckReport(
      value['guard'] as String,
      domains,
      f == null
          ? null
          : ChapterIssue(
              f['id'],
              f['category'],
              f['title'],
              f['evidence'],
              (f['lines'] as List).cast<int>(),
              f['decision'],
              f['reviewed'] == true,
              f['auto'] == true,
              entryId: f['entry'],
              nodeOffset: f['offset'],
            ),
      value['evidence'] as String,
      value['safe'] as int,
      checkedAt: checkedAt,
      schema: schema,
      bookId: value['book_id'] as String? ?? '',
      guards: Map<String, String>.from(value['guards'] as Map? ?? const {}),
      baseline: Map<String, int>.from(value['baseline'] as Map? ?? const {}),
    );
  }
}

/// 文本问题全书每一处的位置，按行号升序，不带文字。上十万处时也只占几列整数。
class CheckSpots {
  const CheckSpots(
    this.lines,
    this.originals,
    this.steps,
    this.rows,
    this.rules,
  );
  static final empty = CheckSpots(
    Int32List(0),
    Int32List(0),
    Int32List(0),
    Int32List(0),
    const [],
  );

  /// 在报告里的序号：变更和候选各自从 0 数，每 40 条一页。
  final Int32List rows;

  /// 有效稿行号；[originals] 是对应的原稿行，没有唯一对应时为 -1。
  final Int32List lines, originals;

  /// 属于第几条规则；广告候选为 -1。
  final Int32List steps;

  /// 这次检查用的规则，下标对应 [steps]。
  final List<String> rules;
  int get length => lines.length;
  bool candidateAt(int index) => steps[index] < 0;

  /// 清理页的差异用原稿行号，对不上时退回有效稿行号。
  int pageLineAt(int index) =>
      originals[index] >= 0 ? originals[index] : lines[index];
}

/// 按项更新：改章节只重算章节，改书籍信息只重算书籍信息。
abstract interface class CheckUpdateSession {
  /// 最新的一份结果，可能落后于书稿；从没检查过时为 null。
  BookCheckReport? get shown;

  /// 只重算对不上书稿的项；同一本书同时只有一次，后来的等它结束。
  Future<BookCheckReport> update();

  /// 这一项的结果对得上当前书稿。
  bool domainCurrent(String id);

  /// 书籍信息问题是直接从设置算的，不用等后台。
  List<CheckFinding> metadataFindings();

  /// 文本问题第 [offset] 条起的一页内容，检查页翻到这里时用。
  Future<List<CleanupCheckItem>> cleanupItemsAt(int offset);

  /// 这一项要查的东西和结果算的时候一样。关掉一项检查后，到结果更新之前为 false。
  bool rulesCurrent(String id);

  /// 文本问题每一处的位置。[pipeline] 是还没采用的规则，不给时用已保存的规则。
  Future<CheckSpots> spots({List<Map<String, dynamic>>? pipeline});

  /// 已经算好存着的位置，不跑清理；没有时为 null。重启后用它。
  Future<CheckSpots?> storedSpots();

  /// 已保存规则的标识，和草稿比较用。
  String get cleanupRulesKey;

  /// 已采用的方案里保留原文的行。检查不重放这些选择，要从结果里去掉。
  Set<int> keptCleanupLines();
}

abstract class CachedBookCheckSession {
  BookCheckReport? get latest;
}

abstract class BookCheckSession {
  Listenable get changes;
  Future<BookCheckReport> inspect();
  bool isCurrent(BookCheckReport report);
  void cancel();
  void dispose();
}

abstract interface class BookCheckProgressSession {
  String get checkPhase;
  bool get checkRunning;
  bool get checkCancelling;
}
