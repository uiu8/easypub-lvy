import 'package:flutter/material.dart';

enum ConversionPreflightLevel { pass, info, warning, blocking }

/// A concrete destination for resolving a preflight issue. Persist this with
/// the report so restored batches retain the same operation entry point.
enum ConversionPreflightAction {
  overview,
  chapters,
  cleanup,
  metadata,
  resources,
}

class ConversionPreflightIssue {
  const ConversionPreflightIssue({
    required this.level,
    required this.title,
    required this.detail,
    this.canOpenRepair = false,
    this.category = 'general',
    this.isCoverIssue = false,
    this.action = ConversionPreflightAction.overview,
  });

  final ConversionPreflightLevel level;
  final String title;
  final String detail;
  final bool canOpenRepair;
  final String category;
  final bool isCoverIssue;
  final ConversionPreflightAction action;

  Map<String, dynamic> toJson() => {
    'level': level.name,
    'title': title,
    'detail': detail,
    'can_open_repair': canOpenRepair,
    'category': category,
    'is_cover_issue': isCoverIssue,
    'action': action.name,
  };

  factory ConversionPreflightIssue.fromJson(Map<String, dynamic> json) {
    final level = ConversionPreflightLevel.values.firstWhere(
      (value) => value.name == json['level'],
      orElse: () => ConversionPreflightLevel.info,
    );
    return ConversionPreflightIssue(
      level: level,
      title: json['title']?.toString() ?? '检查项',
      detail: json['detail']?.toString() ?? '',
      canOpenRepair: json['can_open_repair'] == true,
      category: json['category'] as String? ?? 'general',
      isCoverIssue: json['is_cover_issue'] == true,
      action: ConversionPreflightAction.values.firstWhere(
        (value) => value.name == json['action'],
        orElse: () => ConversionPreflightAction.overview,
      ),
    );
  }
}

class ConversionPreflightReport {
  const ConversionPreflightReport({
    required this.bookId,
    required this.title,
    required this.issues,
  });

  final String bookId;
  final String title;
  final List<ConversionPreflightIssue> issues;

  Map<String, dynamic> toJson() => {
    'book_id': bookId,
    'title': title,
    'issues': issues.map((issue) => issue.toJson()).toList(),
  };

  factory ConversionPreflightReport.fromJson(Map<String, dynamic> json) {
    return ConversionPreflightReport(
      bookId: json['book_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      issues: (json['issues'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (issue) => ConversionPreflightIssue.fromJson(
              issue.cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
    );
  }

  bool get blocking =>
      issues.any((issue) => issue.level == ConversionPreflightLevel.blocking);

  bool get requiresAcknowledgement =>
      issues.any((issue) => issue.level == ConversionPreflightLevel.warning);

  bool get passed => !blocking;

  int count(ConversionPreflightLevel level) =>
      issues.where((issue) => issue.level == level).length;
}

IconData preflightIcon(ConversionPreflightLevel level) => switch (level) {
  ConversionPreflightLevel.pass => Icons.check_circle_outline,
  ConversionPreflightLevel.info => Icons.info_outline,
  ConversionPreflightLevel.warning => Icons.warning_amber_outlined,
  ConversionPreflightLevel.blocking => Icons.block,
};

Color preflightColor(BuildContext context, ConversionPreflightLevel level) {
  final scheme = Theme.of(context).colorScheme;
  return switch (level) {
    ConversionPreflightLevel.pass => scheme.primary,
    ConversionPreflightLevel.info => scheme.onSurfaceVariant,
    ConversionPreflightLevel.warning => scheme.tertiary,
    ConversionPreflightLevel.blocking => scheme.error,
  };
}
