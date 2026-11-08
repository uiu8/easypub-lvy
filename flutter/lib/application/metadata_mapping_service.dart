import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'conversion_snapshot.dart';

const mappingFields = <String, String>{
  'title': '书名',
  'author': '作者',
  'description': '简介',
  'translator': '译者',
  'isbn': 'ISBN',
  'publication_date': '出版日期',
  'publisher': '出版社',
  'category': '类别',
  'series': '系列',
  'series_index': '系列序号',
  'subjects': '主题 / 标签',
  'language': '语言',
  'cover_path': '封面图片',
  'cover_fit': '封面适配',
};
const mappingActions = {
  'keep': '不改',
  'set': '设为指定值',
  'fill_empty': '仅填空值',
  'clear': '清空',
};

class MappingRule {
  MappingRule(
    this.folder,
    Map<String, Map<String, String>> fields, {
    String? id,
  }) : id = id ?? _legacyId(folder),
       fields = Map.unmodifiable(
         fields.map((k, v) => MapEntry(k, Map<String, String>.unmodifiable(v))),
       );
  final String id;
  static String _legacyId(String folder) =>
      'legacy-${publicationFingerprint({'folder': Platform.isWindows ? folder.replaceAll('\\', '/').toLowerCase() : folder.replaceAll('\\', '/')})}';
  String get version =>
      publicationFingerprint({'folder': folder, 'fields': fields});
  factory MappingRule.create(
    String folder,
    Map<String, Map<String, String>> fields,
  ) {
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return MappingRule(folder, fields, id: 'rule-$id');
  }
  MappingRule revised(String folder, Map<String, Map<String, String>> fields) =>
      MappingRule(folder, fields, id: id);
  final String folder;
  final Map<String, Map<String, String>> fields;
  Map<String, dynamic> toJson() => {
    'id': id,
    'version': version,
    'folder': folder,
    'fields': fields,
  };
  factory MappingRule.fromJson(Map value) {
    final rule = MappingRule(
      value['folder'] as String,
      (value['fields'] as Map).map(
        (k, v) => MapEntry(k as String, Map<String, String>.from(v as Map)),
      ),
      id: value['id'] as String?,
    );
    if (value['version'] != null && value['version'] != rule.version) {
      throw const FormatException('规则版本与内容不一致，请重新载入规则。');
    }
    return rule;
  }
  void validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
        !Directory(folder).isAbsolute ||
        folder.length > 32768 ||
        folder.contains('\u0000') ||
        fields.isEmpty) {
      throw const FormatException('规则需要完整的目录路径和字段设置。');
    }
    for (final entry in fields.entries) {
      final key = entry.key, op = entry.value['op'];
      if (!mappingFields.containsKey(key) ||
          !mappingActions.containsKey(op) ||
          (key == 'cover_fit' && op == 'clear')) {
        throw const FormatException('规则字段或应用方式无效。');
      }
      if (op != 'set' && op != 'fill_empty') continue;
      final value = entry.value['value'];
      final limit = key == 'description'
          ? 65536
          : key == 'cover_path'
          ? 32768
          : 4096;
      if (value == null ||
          utf8.encode(value).length > limit ||
          value.contains('\u0000')) {
        throw FormatException('${mappingFields[key]}的规则值无效或过长。');
      }
      if (key == 'cover_path' && !File(value).isAbsolute) {
        throw const FormatException('封面需要完整文件路径。');
      }
      if (key == 'cover_fit' && !['cover', 'contain', 'fill'].contains(value)) {
        throw const FormatException('请选择有效的封面适配方式。');
      }
    }
  }
}

class MappingBookDiff {
  MappingBookDiff({
    required this.bookId,
    required this.before,
    required this.after,
    required this.changed,
    required this.folder,
    required this.candidates,
    required this.actions,
    this.unavailableFolders = const [],
    this.ruleScope = 'global',
  });
  final String bookId;
  final Map<String, Object?> before, after;
  final List<String> changed;
  final String? folder;
  final int candidates;
  final Map<String, String> actions;
  final List<String> unavailableFolders;
  final String ruleScope;
}

class MappingPreview {
  MappingPreview(this.items);
  final List<MappingBookDiff> items;
  int get changedBooks => items.where((b) => b.changed.isNotEmpty).length;
}

abstract class MappingSession {
  List<MappingRule> get rules;
  List<MappingRule> get projectRules;
  Future<void> saveRules(List<MappingRule> rules);
  Future<MappingPreview> preview(List<MappingRule> rules, List<String> targets);
  Future<String> apply(MappingPreview preview);
}

/// Explicit per-book field overrides are re-previewed and confirmed, never
/// inferred from selecting a rule or a book.
abstract interface class MappingOverrideSession {
  Future<MappingPreview> previewOverrides(
    List<MappingRule> rules,
    List<String> targets,
    Map<String, Set<String>> fields, {
    Map<String, Set<String>> restoreFields = const {},
  });
}

abstract interface class ProjectMappingSession {
  bool get editingProject;
  bool get projectEnabled;
  void selectProjectScope(bool project);
  void setProjectEnabled(bool enabled);
}

class MappingSaveImpactItem {
  const MappingSaveImpactItem(this.bookId, this.title, {this.diff, this.error});
  final String bookId, title;
  final MappingBookDiff? diff;
  final String? error;
}

class MappingSaveImpact {
  MappingSaveImpact(List<MappingSaveImpactItem> items)
    : items = List.unmodifiable(items);
  final List<MappingSaveImpactItem> items;
  int get changedBooks =>
      items.where((i) => i.diff?.changed.isNotEmpty ?? false).length;
  int get uncheckedBooks => items.where((i) => i.error != null).length;
}

abstract interface class MappingSaveReviewSession {
  Future<MappingSaveImpact> previewRuleSave(List<MappingRule> rules);
  Future<void> saveReviewedRules(MappingSaveImpact impact);
}
