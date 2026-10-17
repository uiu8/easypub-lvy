import 'dart:convert';

const defaultCleanupPipeline = <Map<String, dynamic>>[
  {'kind': 'trim_trailing_spaces'},
  {'kind': 'collapse_blank_lines'},
  {'kind': 'remove_ad_lines'},
];

class ResolvedCleanupRules {
  ResolvedCleanupRules(this.origin, List<Map<String, dynamic>> rules)
    : pipeline = (jsonDecode(jsonEncode(rules)) as List)
          .map((r) => (r as Map).cast<String, dynamic>())
          .toList();
  final String origin;
  final List<Map<String, dynamic>> pipeline;
  bool get enabled => pipeline.any((r) => r['enabled'] != false);
  String get fingerprint => jsonEncode(['cleanup-rules-v1', origin, pipeline]);
}

/// A present empty list is an explicit override; null continues inheritance.
/// Original-line selections stay in the draft and are never replayed in checks.
ResolvedCleanupRules resolveCleanupRules(
  Map<String, dynamic> configuration, {
  Map<String, dynamic>? bookDraft,
  List<dynamic>? pendingPipeline,
}) {
  List<Map<String, dynamic>>? from(
    Map<String, dynamic> value,
    String pipelineKey,
    String legacyKey,
  ) {
    final pipeline = value[pipelineKey];
    if (pipeline is List) {
      return pipeline.map((r) => (r as Map).cast<String, dynamic>()).toList();
    }
    final legacy = value[legacyKey];
    if (legacy is List) {
      return [
        for (final kind in legacy) {'kind': kind},
      ];
    }
    return null;
  }

  if (pendingPipeline != null) {
    return ResolvedCleanupRules(
      'book',
      pendingPipeline
          .cast<Map>()
          .map((r) => r.cast<String, dynamic>())
          .toList(),
    );
  }
  final book = bookDraft == null ? null : from(bookDraft, 'pipeline', 'rules');
  if (book != null) {
    if (bookDraft?['pipeline'] is! List && bookDraft?['rules'] is List) {
      const legacyOrder = [
        'trim_trailing_spaces',
        'remove_ad_lines',
        'collapse_blank_lines',
      ];
      book.sort(
        (a, b) => legacyOrder
            .indexOf(a['kind'])
            .compareTo(legacyOrder.indexOf(b['kind'])),
      );
    }
    return ResolvedCleanupRules('book', book);
  }
  final global = from(
    configuration,
    'automatic_cleanup_pipeline',
    'automatic_cleanup_rules',
  );
  if (global != null) return ResolvedCleanupRules('global', global);
  return ResolvedCleanupRules('builtin', defaultCleanupPipeline);
}
