import 'dart:convert';

import '../application/chapter_rules_service.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class LegacyChapterRulesSession implements ChapterRulesSession {
  LegacyChapterRulesSession(this.backend, this.bookId);
  final PrototypeState backend;
  final String? bookId;
  @override
  bool get hasBook => bookId != null;
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(await api.chapterRulesText(requestJson: jsonEncode(value)))
            as Map,
      );
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      throw FormatException(
        '${detail['next_action'] ?? '规则操作未完成'}。请检查规则表达式，重新读取本书后预览。',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> builtin() async => Map<String, dynamic>.from(
    (await request({'op': 'defaults'}))['rules'] as Map,
  );
  @override
  Future<Map<String, dynamic>> builtinDescription() =>
      request({'op': 'builtin'});
  @override
  Future<Map<String, dynamic>> load() async {
    if (!backend.globalSettingsLoaded && backend.settingsDirectory != null) {
      await backend.loadGlobalSettings();
    }
    final defaults =
        backend.globalConfiguration['recognition_defaults'] as Map? ??
        await builtin();
    final tree = hasBook
        ? await backend.manuscript.effectiveTree(bookId!, 0)
        : null;
    final activeRules =
        tree?['recognition_rules'] ??
        (hasBook ? {...await builtin(), 'origin': 'legacy'} : defaults);
    final presets = <String, Map<String, dynamic>>{};
    for (final item in [
      ...(backend.globalConfiguration['recognition_presets'] as List? ?? []),
      ...backend.manuscript.recognitionPresets,
    ]) {
      final value = Map<String, dynamic>.from(item as Map);
      presets[value['name'] as String] = value;
    }
    return {
      'rules': activeRules,
      'defaults': defaults,
      'presets': presets.values.toList(),
      'draft': backend.manuscript.recognitionDrafts[bookId ?? r'$defaults'],
      'has_book': hasBook,
    };
  }

  @override
  Future<Map<String, dynamic>> sample(
    Map<String, dynamic> rules,
    String text,
  ) => request({'op': 'sample', 'rules': rules, 'text': text});
  @override
  Future<ChapterRulesPreview> preview(
    Map<String, dynamic> rules, {
    required bool preserveDecisions,
  }) async {
    final id = bookId!;
    final book = backend.shelf.books.firstWhere((b) => b.id == id && !b.isDemo);
    final guard = backend.publicationContext(id);
    final result = await request({
      'op': 'preview',
      'source_id': book.source!.sourceId,
      'revision': book.source!.revision,
      'base': backend.manuscript.effectiveBase(id),
      'post_edits': backend.manuscript.effectiveSelection(id),
      'rules': rules,
      'preserve_decisions': preserveDecisions,
    });
    if (guard != backend.publicationContext(id)) {
      throw const FormatException('书稿已变化，请重新预览。');
    }
    return _Preview(result, this, guard, preserveDecisions);
  }

  @override
  Future<void> apply(ChapterRulesPreview preview) async {
    if (preview is! _Preview ||
        !identical(preview.owner, this) ||
        preview.guard != backend.publicationContext(bookId!)) {
      throw const FormatException('书稿或规则已变化，请重新预览。');
    }
    await backend.manuscript.editEffectiveDraft(bookId!, {
      'op': 'append_batch',
      'actions': [
        {
          'kind': 'recognize',
          'rules': preview.data['rules'],
          'preserve_decisions': preview.preserveDecisions,
        },
      ],
    });
    saveDraft(null);
  }

  @override
  Future<void> saveDefault(Map<String, dynamic> rules) async {
    await request({'op': 'validate', 'rules': rules});
    if (!await backend.saveGlobalConfigurationPatch({
      'recognition_defaults': rules,
    })) {
      throw const FormatException('导入默认规则未能保存，请检查设置目录权限、磁盘空间及文件占用后重试。');
    }
  }

  @override
  Future<void> savePresets(List<Map<String, dynamic>> presets) async {
    if (!await backend.saveGlobalConfigurationPatch({
      'recognition_presets': presets,
    })) {
      throw const FormatException('规则预设未能保存，请检查设置目录权限、磁盘空间及文件占用后重试。');
    }
    backend.change(() => backend.manuscript.recognitionPresets = presets);
  }

  @override
  void saveDraft(Map<String, dynamic>? draft) {
    backend.change(() {
      final key = bookId ?? r'$defaults';
      if (draft == null) {
        backend.manuscript.recognitionDrafts.remove(key);
      } else {
        backend.manuscript.recognitionDrafts[key] = draft;
      }
    });
  }
}

class _Preview extends ChapterRulesPreview {
  const _Preview(super.data, this.owner, this.guard, this.preserveDecisions);
  final LegacyChapterRulesSession owner;
  final String guard;
  final bool preserveDecisions;
}
