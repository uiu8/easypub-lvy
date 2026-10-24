import 'package:flutter/foundation.dart';

class RuleDescriptor {
  RuleDescriptor.fromJson(Map v)
    : id = v['id'] as String,
      group = v['group'] as String,
      parent = v['parent'] as String?,
      label = v['label'] as String,
      description = v['description'] as String,
      effect = v['effect'] as String,
      category = v['category'] as String,
      toggle = v['toggle'] == null
          ? null
          : Map<String, dynamic>.unmodifiable(v['toggle'] as Map),
      defaultEnabled = v['default'] as bool,
      order = v['order'] as int,
      locked = v['locked'] == true,
      lockedReason = v['locked_reason'] as String?,
      offValue = v['off_value'],
      onValue = v['on_value'];
  final bool locked;
  final String? lockedReason;
  final Object? offValue, onValue;
  final String id, group, label, description, effect, category;
  final String? parent;
  final Map<String, dynamic>? toggle;
  final bool defaultEnabled;
  final int order;
}

class RuleLocation {
  RuleLocation.fromJson(Map v)
    : entryId = v['entry_id'] as String,
      firstLine = v['first_line'] as int,
      lastLine = v['last_line'] as int,
      sourceLine = v['source_line'] as int,
      utf8Start = v['utf8_start'] as int,
      heading = v['heading'] as bool;
  final String entryId;

  /// 正文行从 1 开始；标题位置为 0，并且 heading 为 true。
  final int firstLine, lastLine, sourceLine, utf8Start;
  final bool heading;
}

class RuleLineRange {
  const RuleLineRange(this.first, this.last);
  final int first, last;
}

class RuleStatistic {
  RuleStatistic.fromJson(Map v)
    : id = v['id'] as String,
      enabled = v['enabled'] as bool,
      hypothetical = v['hypothetical'] == true,
      count = v['count'] as int? ?? 0,
      countAvailable = v['count'] != null,
      affects = List.unmodifiable(
        (v['affects'] as List? ?? []).cast<Map>().map(
          (r) => Map<String, dynamic>.unmodifiable(r),
        ),
      ),
      unit = v['unit'] as String,
      status = v['status'] as String,
      reason = v['reason'] as String?,
      invalidCount = v['invalid_count'] as int,
      locations = List.unmodifiable(
        (v['locations'] as List).cast<Map>().map(RuleLocation.fromJson),
      ),
      changedRanges = _ranges(v['changed_ranges'] as List),
      candidateRanges = _ranges(v['candidate_ranges'] as List);
  static List<RuleLineRange> _ranges(List v) => List.unmodifiable(
    v.cast<List>().map((r) => RuleLineRange(r[0] as int, r[1] as int)),
  );
  final String id, unit, status;
  final String? reason;
  final bool enabled;
  final int count, invalidCount;
  final bool countAvailable;
  final bool hypothetical;
  final List<Map<String, dynamic>> affects;
  final List<RuleLocation> locations;

  /// 完整的当前有效书稿行范围，首尾都包含；不受 locations 的 50 处限制。
  final List<RuleLineRange> changedRanges, candidateRanges;
}

class RuleStatisticsSnapshot {
  RuleStatisticsSnapshot.fromJson(Map v)
    : contentId = v['content_id'] as String,
      configFingerprint = v['config_fingerprint'] as String,
      cacheHit = v['cache_hit'] as bool,
      elapsedMilliseconds = (v['elapsed_ms'] as num).toDouble(),
      byteLength = v['byte_length'] as int,
      lineCount = v['line_count'] as int,
      chapterCount = v['chapter_count'] as int,
      rules = Map.unmodifiable({
        for (final r in (v['rules'] as List).cast<Map>())
          r['id'] as String: RuleStatistic.fromJson(r),
      }),
      layoutLines = Map.unmodifiable({
        for (final e in (v['layout_lines'] as Map? ?? const {}).entries)
          e.key as String: List<LayoutLine>.unmodifiable([
            for (final r in (e.value as List).cast<List>())
              LayoutLine(
                r[0] as int,
                r[1] as String,
                r[2] as String,
                r[3] == true,
              ),
          ]),
      });
  final String contentId, configFingerprint;
  final bool cacheHit;

  /// 首次计算耗时；缓存命中时仍保留原计算耗时。
  final double elapsedMilliseconds;
  final int byteLength, lineCount, chapterCount;
  final Map<String, RuleStatistic> rules;

  /// 按当前设置逐行识别出的块（V104，LAY-148）：章节编号 → 各行。
  final Map<String, List<LayoutLine>> layoutLines;
}

/// 一行的识别结果（V104，LAY-148）：本节正文行号（从 1 开始）、类别（system、verse、chat、inset、
/// 手工标注的 letter、quote 等）、成品里的 CSS 类（如 verse-by），以及是否来自手工标注。
class LayoutLine {
  const LayoutLine(this.line, this.kind, this.css, this.manual);
  final int line;
  final String kind, css;
  final bool manual;
}

enum RuleStatisticsPhase {
  idle,
  running,
  cancelling,
  completed,
  cancelled,
  stale,
  failed,
}

class RuleStatisticsState {
  const RuleStatisticsState(this.phase, {this.result, this.reason});
  final RuleStatisticsPhase phase;
  final RuleStatisticsSnapshot? result;
  final String? reason;
}

/// 章节问题对应的规则编号（V64，CH-279）：类别 number-gap 对应 check.number_gap；
/// 编号重复 / 编号回退两个细分对应“编号回退或重复”下的细分规则。
String chapterIssueRule(String category, String? subtype) {
  final base = 'check.${category.replaceAll('-', '_')}';
  return switch (subtype) {
    'repeated-number' => '$base.repeated_number',
    'number-reversal' => '$base.number_reversal',
    _ => base,
  };
}

abstract interface class RuleCatalogLibrary {
  RuleCatalogService openRuleCatalog(String bookId);
}

/// 每本书一个只读服务。配置或有效书稿变化时，旧结果失效并取消在途计算。
abstract interface class RuleCatalogService {
  Future<Map<String, dynamic>> settings({String scope = 'book'});
  Future<Map<String, dynamic>> previewToggles(
    List<Map<String, dynamic>> changes, {
    String scope = 'book',
  });
  Future<void> applyToggles(String planId);
  ValueListenable<RuleStatisticsState> get state;
  Future<List<RuleDescriptor>> catalog();

  /// 同一服务一次只运行一个请求；取消后等待本次 Future 结束再请求。
  /// 取消或版本失效时返回 null。
  Future<RuleStatisticsSnapshot?> request();
  Future<void> cancel();
  void dispose();
}
