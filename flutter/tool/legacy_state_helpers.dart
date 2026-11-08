import 'dart:convert';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/state/cleanup_store.dart';
import 'package:easypub_desktop/state/production_store.dart';

// V39：旧原型的几个薄包装。生产代码不用，只给 `tool/` 下的历史验证脚本搭建场景；
// 方法体与 V39 删除前的生产源码相同，全部只经公开接口。

extension LegacyGlobalSaves on PrototypeState {
  Future<bool> saveGlobalLayout(
    Map<String, dynamic> values,
    String? expectedToken,
  ) => saveGlobalConfiguration(
    Map<String, dynamic>.from(globalConfiguration)
      ..['layout_defaults'] = values,
    expectedToken,
  );

  Future<bool> saveGlobalMigration(
    Map<String, dynamic> defaults,
    List<Map<String, dynamic>> presets,
    String? expectedToken,
  ) => saveGlobalConfiguration(
    Map<String, dynamic>.from(globalConfiguration)
      ..['layout_defaults'] = defaults
      ..['layout_presets'] = jsonDecode(jsonEncode(presets)),
    expectedToken,
  );

  Future<bool> saveGlobalCleanupPresets(
    List<Map<String, dynamic>> presets,
    String? expectedToken,
  ) => saveGlobalConfiguration(
    Map<String, dynamic>.from(globalConfiguration)
      ..['cleanup_presets'] = jsonDecode(jsonEncode(presets)),
    expectedToken,
  );

  Future<bool> saveGlobalMigrationWithCleanup(
    Map<String, dynamic> defaults,
    List<Map<String, dynamic>> presets,
    List<Map<String, dynamic>> cleanupPresets,
    String? expectedToken,
  ) => saveGlobalConfiguration(
    Map<String, dynamic>.from(globalConfiguration)
      ..['layout_defaults'] = defaults
      ..['layout_presets'] = jsonDecode(jsonEncode(presets))
      ..['cleanup_presets'] = jsonDecode(jsonEncode(cleanupPresets)),
    expectedToken,
  );

  BookDraft draftFor(String bookId) => production.drafts.putIfAbsent(
    bookId,
    () => BookDraft(shelf.books.firstWhere((book) => book.id == bookId)),
  );
}

extension LegacyCleanupSaves on CleanupStore {
  Future<void> saveSettings(String bookId, Map<String, dynamic> request) async {
    if (!await editSettings(bookId, {'op': 'set', 'request': request})) {
      throw FormatException(historyStatus[bookId] ?? '清理设置未保存，请检查规则或项目状态。');
    }
  }
}

extension LegacyResourceCopy on ProductionStore {
  Future<ProductionPreview> previewResources(
    String templateBookId,
    List<String> targets, {
    required bool copyMetadata,
    required bool copyCover,
    required bool copyTypography,
    required bool copyIllustrations,
    required bool overwrite,
    Map<String, String> fieldActions = const {},
  }) {
    final values = settings(templateBookId);
    final changes = <String, Map<String, dynamic>>{};
    final selected = <String>{
      if (copyMetadata) ...[
        'title',
        'author',
        'description',
        ...bibliographicFields.keys,
      ],
      if (copyCover) ...[
        'cover_path',
        'cover_fit',
        'cover_crop',
        'cover_design',
      ],
      if (copyTypography) ...[
        'font_family',
        'font_resource',
        'font_size',
        'font_size_unit',
        'fullwidth_indent',
        'remove_blank_lines',
        'line_height',
        'text_alignment',
        'writing_mode',
        'vertical_digits',
        'heading_style',
        'additional_css',
        'additional_css_base',
        'additional_css_bundle',
        'paragraph_indent',
        'paragraph_spacing',
        'margin_top',
        'margin_top_unit',
        'margin_right',
        'margin_right_unit',
        'margin_bottom',
        'margin_bottom_unit',
        'margin_left',
        'margin_left_unit',
        'include_toc',
        'visible_toc',
        'chapter_navigation',
      ],
      if (copyIllustrations) 'illustrations',
      ...fieldActions.keys,
      if (fieldActions.containsKey('additional_css')) ...[
        'additional_css_base',
        'additional_css_bundle',
      ],
    };
    if (selected.isEmpty) throw const FormatException('请至少选择一项制作字段。');
    for (final id in targets.toSet()) {
      final target = settings(id);
      final fields = <String, dynamic>{};
      for (final key in selected) {
        var op = fieldActions[key] ?? (overwrite ? 'set' : 'fill_empty');
        if ((key == 'cover_fit' ||
                key == 'cover_crop' ||
                key == 'cover_design') &&
            !overwrite &&
            !fieldActions.containsKey(key)) {
          op = target['cover_path'] == null ? 'set' : 'keep';
        }
        if ((key == 'additional_css_base' || key == 'additional_css_bundle') &&
            !fieldActions.containsKey(key)) {
          final cssOp =
              fieldActions['additional_css'] ??
              (overwrite ? 'set' : 'fill_empty');
          op = switch (cssOp) {
            'set' => 'set',
            'clear' => 'clear',
            'fill_empty' =>
              (target['additional_css'] as String).trim().isEmpty
                  ? 'set'
                  : 'keep',
            _ => 'keep',
          };
        }
        dynamic value = values[key];
        if (key == 'illustrations' && id != templateBookId) {
          value = (value as List)
              .map(
                (item) =>
                    Map<String, dynamic>.from(item as Map)
                      ..remove('source_line'),
              )
              .toList();
        }
        fields[key] = {
          'op': op,
          if (op == 'set' || op == 'fill_empty') 'value': value,
        };
      }
      changes[id] = {'op': 'patch', 'fields': fields};
    }
    return previewChanges(changes, additionalGuards: {templateBookId});
  }
}
