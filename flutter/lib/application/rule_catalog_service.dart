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
      order = v['order'] as int;
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
      count = v['count'] as int,
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
      });
  final String contentId, configFingerprint;
  final bool cacheHit;

  /// 首次计算耗时；缓存命中时仍保留原计算耗时。
  final double elapsedMilliseconds;
  final int byteLength, lineCount, chapterCount;
  final Map<String, RuleStatistic> rules;
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

abstract interface class RuleCatalogLibrary {
  RuleCatalogService openRuleCatalog(String bookId);
}

/// 每本书一个只读服务。配置或有效书稿变化时，旧结果失效并取消在途计算。
abstract interface class RuleCatalogService {
  ValueListenable<RuleStatisticsState> get state;
  Future<List<RuleDescriptor>> catalog();

  /// 同一服务一次只运行一个请求；取消后等待本次 Future 结束再请求。
  /// 取消或版本失效时返回 null。
  Future<RuleStatisticsSnapshot?> request();
  Future<void> cancel();
  void dispose();
}
