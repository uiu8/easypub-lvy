import '../src/rust/api.dart' as api;

import 'dart:convert';

import '../application/metadata_mapping_service.dart';
import '../prototype/prototype_state.dart';

/// Nonvisual bridge; production preview stays private and cannot be forged by UI.
class LegacyMappingSession
    implements
        MappingSession,
        MappingOverrideSession,
        ProjectMappingSession,
        MappingSaveReviewSession {
  LegacyMappingSession(this.backend) : _guard = _configuration(backend);
  final PrototypeState backend;
  static String _configuration(PrototypeState backend) => jsonEncode([
    backend.projectPath,
    backend.globalFolderRules,
    backend.folderRules,
    backend.projectFolderRulesEnabled,
  ]);
  @override
  bool editingProject = false;
  @override
  bool get projectEnabled =>
      backend.projectFolderRulesEnabled || _previewProjectActivation;
  bool _previewProjectActivation = false;
  @override
  void selectProjectScope(bool project) {
    _fresh();
    editingProject = project;
    _pending = null;
    _exposed = null;
  }

  @override
  void setProjectEnabled(bool enabled) {
    _fresh();
    backend.change(() => backend.projectFolderRulesEnabled = enabled);
    _guard = _configuration(backend);
    _pending = null;
    _exposed = null;
  }

  int _saveGeneration = 0;
  MappingSaveImpact? _saveImpact;
  List<MappingRule>? _saveRules;
  String? _saveContext;
  String _impactContext() => jsonEncode([
    _configuration(backend),
    editingProject,
    for (final book in backend.shelf.books.where(
      (b) => !b.isDemo && b.source != null,
    ))
      [book.id, backend.publicationContext(book.id)],
  ]);
  @override
  Future<MappingSaveImpact> previewRuleSave(List<MappingRule> rules) async {
    _validate(rules);
    final generation = ++_saveGeneration;
    _saveImpact = null;
    _saveRules = null;
    _saveContext = null;
    final frozen = List<MappingRule>.unmodifiable(
      rules.map((r) => MappingRule.fromJson(r.toJson())),
    );
    final guard = _impactContext();
    final books = backend.shelf.books
        .where((b) => !b.isDemo && b.source != null)
        .toList();
    final probe = LegacyMappingSession(backend)
      ..editingProject = editingProject
      .._previewProjectActivation = editingProject;
    final items = <MappingSaveImpactItem>[];
    for (final book in books) {
      _fresh();
      try {
        final result = await probe.preview(frozen, [book.id]);
        items.add(
          MappingSaveImpactItem(book.id, book.title, diff: result.items.single),
        );
      } catch (error) {
        items.add(
          MappingSaveImpactItem(
            book.id,
            book.title,
            error: error is FormatException
                ? error.message.toString()
                : '无法核对本书，请检查原稿、目录或规则资源后重新预览。',
          ),
        );
      }
    }
    _fresh();
    if (generation != _saveGeneration || guard != _impactContext()) {
      throw const FormatException('书库或核对请求已变化，请重新核对规则影响。');
    }
    final result = MappingSaveImpact(items);
    _saveImpact = result;
    _saveRules = frozen;
    _saveContext = guard;
    return result;
  }

  @override
  Future<void> saveReviewedRules(MappingSaveImpact impact) async {
    _fresh();
    if (!identical(impact, _saveImpact) ||
        _saveRules == null ||
        _saveContext != _impactContext()) {
      throw const FormatException('规则影响核对已过期，请重新核对后保存。');
    }
    final rules = _saveRules!;
    _saveImpact = null;
    _saveRules = null;
    _saveContext = null;
    await saveRules(rules);
  }

  String _guard;
  ProductionPreview? _pending;
  MappingPreview? _exposed;
  void _fresh() {
    if (backend.projectBusy ||
        backend.production.busy ||
        backend.importing ||
        _configuration(backend) != _guard) {
      throw const FormatException('书库或项目已改变，请重新打开元数据映射。');
    }
  }

  @override
  List<MappingRule> get rules =>
      (editingProject ? backend.folderRules : backend.globalFolderRules)
          .map(MappingRule.fromJson)
          .toList();
  @override
  List<MappingRule> get projectRules =>
      backend.folderRules.map(MappingRule.fromJson).toList();
  void _validate(List<MappingRule> rules) {
    _fresh();
    if (rules.length > 128) throw const FormatException('最多保存 128 条规则。');
    for (final rule in rules) {
      rule.validate();
    }
  }

  @override
  Future<void> saveRules(List<MappingRule> rules) async {
    _validate(rules);
    _saveGeneration++;
    _saveImpact = null;
    _saveRules = null;
    _saveContext = null;
    final values = rules.map((r) => r.toJson()).toList();
    if (editingProject) {
      backend.change(() {
        backend.folderRules = values;
        backend.projectFolderRulesEnabled = true;
      });
      _guard = _configuration(backend);
      _pending = null;
      _exposed = null;
      return;
    }
    if (!await backend.saveGlobalFolderRules(values)) {
      throw FormatException(
        backend.globalSettingsStatus.isEmpty
            ? '规则保存失败，请检查设置目录或重新载入规则。'
            : backend.globalSettingsStatus,
      );
    }
    _guard = _configuration(backend);
    _pending = null;
    _exposed = null;
  }

  @override
  Future<MappingPreview> preview(
    List<MappingRule> rules,
    List<String> targets,
  ) async {
    return previewOverrides(rules, targets, const {});
  }

  @override
  Future<MappingPreview> previewOverrides(
    List<MappingRule> rules,
    List<String> targets,
    Map<String, Set<String>> fields, {
    Map<String, Set<String>> restoreFields = const {},
  }) async {
    _validate(rules);
    if (restoreFields.keys.any((id) => !targets.contains(id)) ||
        restoreFields.entries.any(
          (e) => e.value.any(
            (key) =>
                !mappingFields.containsKey(key) ||
                (fields[e.key]?.contains(key) ?? false),
          ),
        )) {
      throw const FormatException('恢复继承字段无效或与覆盖操作冲突。');
    }
    if (fields.keys.any((id) => !targets.contains(id)) ||
        fields.values.any(
          (keys) => keys.any((key) => !mappingFields.containsKey(key)),
        )) {
      throw const FormatException('覆盖字段或目标书稿无效。');
    }
    _pending = null;
    _exposed = null;
    final globals = editingProject
        ? backend.globalFolderRules.map(MappingRule.fromJson).toList()
        : rules;
    final projects = projectEnabled
        ? (editingProject ? rules : projectRules)
        : <MappingRule>[];
    final usedRules = [...globals, ...projects];
    final resolvedRules = [
      for (final rule in globals) {...rule.toJson(), 'priority': 0},
      for (final rule in projects) {...rule.toJson(), 'priority': 1},
    ];
    final ProductionPreview result;
    try {
      result = await backend.previewFolderMapping(
        resolvedRules,
        targets,
        overrides: fields,
        restoreFields: restoreFields,
      );
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      if (detail['operation'] == 'folder_mapping_cover_restore_unknown') {
        throw const FormatException(
          '封面方案或裁切缺少可恢复的来源记录。请先在书籍信息中核对封面设置，再恢复继承；书稿未修改。',
        );
      }
      if (detail['operation'] == 'folder_mapping_inherited_rule_offline') {
        throw const FormatException(
          '已采用的目录规则当前不可访问，可能已修改路径。请恢复目录后重新预览，或明确删除该规则；现有书稿和历史未改动。',
        );
      }
      rethrow;
    }
    _fresh();
    final items = (result.result['items'] as List).cast<Map>();
    final exposed = MappingPreview(
      List.unmodifiable(
        items.map((item) {
          final resolution = item['mapping'] as Map;
          final winner = resolution['winner'] as int?;
          return MappingBookDiff(
            bookId: item['book_id'] as String,
            before: Map.unmodifiable(
              Map<String, Object?>.from(item['before'] as Map),
            ),
            after: Map.unmodifiable(
              Map<String, Object?>.from(item['after'] as Map),
            ),
            changed: List.unmodifiable(
              (item['changed_fields'] as List).cast<String>(),
            ),
            folder: winner == null ? null : usedRules[winner].folder,
            ruleScope: winner != null && winner >= globals.length
                ? 'project'
                : 'global',
            candidates: (resolution['candidates'] as List).length,
            unavailableFolders: List.unmodifiable(
              (resolution['unavailable'] as List? ?? const []).map(
                (i) => usedRules[i as int].folder,
              ),
            ),
            actions: Map.unmodifiable(
              winner == null
                  ? <String, String>{}
                  : usedRules[winner].fields.map(
                      (key, edit) => MapEntry(key, edit['op']!),
                    ),
            ),
          );
        }),
      ),
    );
    _pending = result;
    _exposed = exposed;
    return exposed;
  }

  @override
  Future<String> apply(MappingPreview preview) async {
    _fresh();
    if (!identical(preview, _exposed) || _pending == null) {
      throw const FormatException('请重新预览后再确认。');
    }
    final plan = _pending!;
    _pending = null;
    _exposed = null;
    if (!await backend.production.confirm(plan)) {
      throw FormatException(backend.production.batchStatus);
    }
    _guard = _configuration(backend);
    return backend.production.batchStatus;
  }
}
