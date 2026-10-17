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

/// 文本清理检测的一条结果（CHK-055）：结构化保存，供检查页按规则分组显示。
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

/// 检查报告的格式版本（V19，CHK-060）。报告格式改变时加一；低于它的报告
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
  });
  final String guard;

  /// 报告的格式版本；没有版本号的旧报告读取时归类一次，见 [BookCheckReport.fromJson]。
  final int schema;

  /// 书的标识（V19 起写入），用于按书回收缓存；更早的报告为空。
  final String bookId;

  /// 需要重新检查才能按当前方式显示（CHK-058/060）。
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
    // V19 前的报告没有版本号：只在这里按 V14 的规则归类一次。没有检查时间，
    // 或文本清理只有文字清单（V12 前）的为 0，其余为 1。
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
    );
  }
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
