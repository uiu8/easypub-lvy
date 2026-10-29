// 每本书的制作设置（书籍信息、封面、插图、排版）与其历史、资源核对（V20 从 PrototypeState 拆出）。
// 只通过 PrototypeState 的公开接口读写书库与章节；行为与拆分前相同。
import 'dart:convert';

import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class ProductionStore {
  ProductionStore(this._core);
  final PrototypeState _core;

  String batchStatus = '';

  final drafts = <String, BookDraft>{};

  /// Resource review survives a project round trip in the book draft. The
  /// importer attaches the same manifest to the source for a live session;
  /// use the draft as the fallback after reopening a project.
  Map<String, dynamic>? importedResourcesFor(String bookId) {
    final draftResources = drafts[bookId]?.epubResources;
    if (draftResources != null) return draftResources;
    for (final book in _core.shelf.books) {
      if (book.id == bookId) return book.source?.resourceReport;
    }
    return null;
  }

  String? coverPathFor(SampleBook book) => drafts[book.id]?.coverPath;

  final coverInputs = <String, String>{};

  List<Map<String, dynamic>> illustrationsFor(String bookId) => drafts
      .putIfAbsent(
        bookId,
        () => BookDraft(
          _core.shelf.books.firstWhere((book) => book.id == bookId),
        ),
      )
      .illustrations;

  Future<Map<String, dynamic>> publicationResources(String bookId) async {
    final guard = _core.publicationContext(bookId);
    final raw = await api.publicationResourcesText(
      requestJson: jsonEncode(_core.publicationRequest(bookId)),
    );
    if (_core.publicationContext(bookId) != guard) {
      throw const FormatException('制作或编辑设置已改变，请重新检查。');
    }
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Future<List<Map<String, dynamic>>> illustrationPositions(
    String bookId,
  ) async {
    final book = _core.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final guard = _core.illustrationContext(bookId);
    final draft = _core.manuscript.manualEditDrafts[bookId];
    final actions = draft == null
        ? null
        : (draft['history'] as List)[draft['cursor'] as int] as List;
    final raw = await api.illustrationPositionsText(
      sourceId: book.source!.sourceId,
      revision: book.source!.revision,
      requestJson: jsonEncode({
        'source_lines': illustrationsFor(bookId)
            .map((i) => i['source_line'])
            .toList(),
        if (_core.manuscript.structures[bookId] != null)
          'structure': _core.manuscript.structures[bookId],
        if (actions != null && actions.isNotEmpty)
          'manual': {'kind': 'manual_batch', 'actions': actions},
        if (_core.cleanup.drafts[bookId] != null)
          'cleanup': _core.cleanup.drafts[bookId],
        'post_edits': _core.manuscript.effectiveSelection(bookId),
      }),
    );
    if (_core.illustrationContext(bookId) != guard) {
      throw const FormatException('编辑状态已改变，请重新检查插图位置。');
    }
    return ((jsonDecode(raw) as Map)['positions'] as List)
        .map((i) => (i as Map).cast<String, dynamic>())
        .toList();
  }

  final resourceIssues = <String, List<Map<String, dynamic>>>{};

  /// Latest resource report is an inspection snapshot. Its guard prevents
  /// an older report from being presented as current after edits.
  final publicationReports = <String, Map<String, dynamic>>{};

  final histories = <String, Map<String, dynamic>>{};

  bool busy = false;

  Map<String, dynamic> settings(String id) {
    final book = _core.shelf.books.firstWhere((b) => b.id == id && !b.isDemo);
    return valuesOf(drafts[id] ?? BookDraft(book));
  }

  Map<String, dynamic> valuesOf(BookDraft d) {
    final values = <String, dynamic>{
      'title': d.title,
      'author': d.author,
      'description': d.description,
      ...d.bibliographic,
      'cover_path': d.coverPath,
      'cover_fit': d.coverFit,
      'cover_crop': d.coverCrop,
      'cover_design': d.coverDesign,
      'font_family': d.fontFamily,
      'font_resource': d.fontResource,
      'font_size': d.fontSize,
      'font_size_unit': d.fontSizeUnit,
      'fullwidth_indent': d.fullwidthIndent,
      'remove_blank_lines': d.removeBlankLines,
      'line_height': d.lineHeight,
      'text_alignment': d.textAlignment,
      'writing_mode': d.writingMode,
      'vertical_digits': d.verticalDigits,
      'heading_style': d.headingStyle,
      'rule_options': d.ruleOptions,
      'scene_break_style': d.sceneBreakStyle,
      'note_style': d.noteStyle,
      'first_paragraph_style': d.firstParagraphStyle,
      'rare_char_ruby': d.rareCharRuby,
      'rare_char_scope': d.rareCharScope,
      'chat_block_style': d.chatBlockStyle,
      'letter_block_style': d.letterBlockStyle,
      'inset_font': d.insetFont,
      'inset_detect': d.insetDetect,
      'inset_styles': d.insetStyles,
      'chapter_head_image': d.chapterHeadImage,
      'chapter_style': d.chapterStyle,
      'chapter_head_scope': d.chapterHeadScope,
      'chapter_head_width': d.chapterHeadWidth,
      'system_block_style': d.systemBlockStyle,
      'system_styles': d.systemStyles,
      'verse_block_style': d.verseBlockStyle,
      if (d.blockAnnotations.isNotEmpty)
        'block_annotations': d.blockAnnotations,
      if (d.manualNotes.isNotEmpty) 'manual_notes': d.manualNotes,
      if (d.inlineStyles.isNotEmpty) 'inline_styles': d.inlineStyles,
      if (d.supplementalPages.isNotEmpty)
        'supplemental_pages': d.supplementalPages,
      'additional_css': d.additionalCss,
      'additional_css_base': d.additionalCssBase,
      'additional_css_bundle': d.additionalCssBundle,
      'css_font_permissions': d.cssFontPermissions,
      'paragraph_indent': d.paragraphIndent,
      'paragraph_spacing': d.paragraphSpacing,
      'margin_top': d.marginTop,
      'margin_top_unit': d.marginTopUnit,
      'margin_right': d.marginRight,
      'margin_right_unit': d.marginRightUnit,
      'margin_bottom': d.marginBottom,
      'margin_bottom_unit': d.marginBottomUnit,
      'margin_left': d.marginLeft,
      'margin_left_unit': d.marginLeftUnit,
      'include_toc': d.includeToc,
      'visible_toc': d.visibleToc,
      'chapter_navigation': d.chapterNavigation,
      'illustrations': d.illustrations
          .map((item) => Map<String, dynamic>.from(item))
          .toList(),
    };
    if (d.metadataOrigins.isNotEmpty) {
      values['metadata_origins'] = {
        for (final entry in d.metadataOrigins.entries)
          entry.key:
              jsonEncode((entry.value as Map)['value']) ==
                  jsonEncode(values[entry.key])
              ? Map<String, dynamic>.from(entry.value as Map)
              : {
                  ...Map<String, dynamic>.from(entry.value as Map),
                  'source': 'manual',
                  'value': values[entry.key],
                },
      };
    }
    if (d.layoutOrigins.isNotEmpty) {
      values['layout_origins'] = {
        for (final entry in d.layoutOrigins.entries)
          entry.key: (entry.value as Map)['value'] == values[entry.key]
              ? Map<String, dynamic>.from(entry.value as Map)
              : {'source': 'book', 'value': values[entry.key]},
      };
    }
    return values;
  }

  String guardFor(String id) => jsonEncode(guardInputs(id));

  /// [guardFor] 的组成部分。稿件版本直接嵌入它们（V117）：嵌入已编码的 [guardFor] 字符串会把
  /// 约 5 KB 的设置再转义编码一次，书库每次刷新给每本书算一遍，300 本时约占刷新的六成。
  List<Object?> guardInputs(String id) {
    final b = _core.shelf.books.firstWhere((b) => b.id == id && !b.isDemo);
    return [
      b.source!.sourceId,
      b.source!.revision,
      settings(id),
      histories[id],
      _core.bookMembership[id] ?? 0,
      _core.removalEpoch,
    ];
  }

  Future<Map<String, dynamic>> productionRequest(
    String request, {
    bool apply = false,
    String planId = '',
    bool confirmed = false,
  }) async => (jsonDecode(
    await api.productionBatchText(
      requestJson: request,
      apply: apply,
      planId: planId,
      confirmed: confirmed,
    ),
  ) as Map).cast<String, dynamic>();

  Future<ProductionPreview> previewChanges(
    Map<String, Map<String, dynamic>> changes, {
    Set<String> additionalGuards = const {},
  }) async {
    if (changes.isEmpty) throw const FormatException('没有选择目标书稿。');
    final guard = {
      for (final id in {...changes.keys, ...additionalGuards}) id: guardFor(id),
    };
    final request = jsonEncode({
      'targets': changes.entries.map((e) {
        final b = _core.shelf.books.firstWhere(
          (b) => b.id == e.key && !b.isDemo,
        );
        final current = settings(e.key);
        return {
          'book_id': e.key,
          'current': current,
          'history':
              histories[e.key] ??
              {
                'source_id': b.source!.sourceId,
                'revision': b.source!.revision,
                'states': [current],
                'cursor': 0,
              },
          'change': e.value,
        };
      }).toList(),
    });
    final result = await productionRequest(request);
    final preview = ProductionPreview(request, result, guard);
    if (!_stillCurrent(preview)) {
      throw const FormatException('书稿或制作设置已改变，请重新预览。');
    }
    return preview;
  }

  bool _stillCurrent(ProductionPreview p) {
    try {
      if (!p.compositionGuards.entries.every(
        (e) => _core.illustrationContext(e.key) == e.value,
      )) {
        return false;
      }
      return p.guard.entries.every((e) => guardFor(e.key) == e.value);
    } catch (_) {
      return false;
    }
  }

  /// Decodes a validated production snapshot without publishing it.
  BookDraft draftFromProduction(
    SampleBook book,
    Map v,
    Map<String, dynamic>? resources,
  ) {
    final d = BookDraft(book)
      ..epubResources = resources
      ..ruleToggleHistory = drafts[book.id]?.ruleToggleHistory;
    d
      ..metadataOrigins = Map<String, dynamic>.from(
        v['metadata_origins'] as Map? ?? {},
      )
      ..layoutOrigins = Map<String, dynamic>.from(
        v['layout_origins'] as Map? ?? {},
      )
      ..title = v['title'] as String
      ..author = v['author'] as String
      ..description = v['description'] as String
      ..bibliographic = {
        for (final key in bibliographicFields.keys)
          key: v[key] as String? ?? '',
      }
      ..coverPath = v['cover_path'] as String?
      ..coverFit = v['cover_fit'] as String
      ..coverCrop = (v['cover_crop'] as Map?)?.cast<String, dynamic>()
      ..coverDesign = (v['cover_design'] as Map?)?.cast<String, dynamic>()
      ..fontFamily = v['font_family'] as String
      ..fontResource = (v['font_resource'] as Map?)?.cast<String, dynamic>()
      ..fontSize = (v['font_size'] as num).toDouble()
      ..fontSizeUnit = v['font_size_unit'] as String? ?? 'px'
      ..fullwidthIndent = (v['fullwidth_indent'] as num? ?? 0).toInt()
      ..removeBlankLines = v['remove_blank_lines'] == true
      ..lineHeight = (v['line_height'] as num).toDouble()
      ..textAlignment = v['text_alignment'] as String? ?? 'start'
      ..writingMode = v['writing_mode'] as String? ?? 'horizontal'
      ..verticalDigits = (v['vertical_digits'] as num? ?? 2).toInt()
      ..headingStyle = v['heading_style'] as String? ?? 'classic'
      ..ruleOptions = Map<String, dynamic>.from(v['rule_options'] as Map? ?? {})
      ..sceneBreakStyle = v['scene_break_style'] as String? ?? 'keep'
      ..noteStyle = v['note_style'] as String? ?? 'off'
      ..firstParagraphStyle = v['first_paragraph_style'] as String? ?? 'normal'
      ..rareCharRuby = v['rare_char_ruby'] as String? ?? 'off'
      ..rareCharScope = v['rare_char_scope'] as String? ?? 'outside'
      ..chatBlockStyle = v['chat_block_style'] as String? ?? 'off'
      ..letterBlockStyle = v['letter_block_style'] as String? ?? 'plain'
      ..insetFont = v['inset_font'] as String? ?? 'kai'
      ..insetDetect = v['inset_detect'] as String? ?? 'off'
      ..insetStyles = (v['inset_styles'] as Map?)?.cast<String, dynamic>()
      ..chapterHeadImage = v['chapter_head_image'] as String?
      ..chapterStyle = (v['chapter_style'] as Map?)?.cast<String, dynamic>()
      ..chapterHeadScope = v['chapter_head_scope'] as String? ?? 'chapter'
      ..chapterHeadWidth = v['chapter_head_width'] as String? ?? 'half'
      ..systemBlockStyle = v['system_block_style'] as String? ?? 'box'
      ..systemStyles = (v['system_styles'] as Map?)?.cast<String, dynamic>()
      ..verseBlockStyle = v['verse_block_style'] as String? ?? 'center'
      ..blockAnnotations = (v['block_annotations'] as List? ?? [])
          .map((a) => Map<String, dynamic>.from(a as Map))
          .toList()
      ..manualNotes = (v['manual_notes'] as List? ?? [])
          .map((a) => Map<String, dynamic>.from(a as Map))
          .toList()
      ..inlineStyles = (v['inline_styles'] as List? ?? [])
          .map((a) => Map<String, dynamic>.from(a as Map))
          .toList()
      ..supplementalPages = (v['supplemental_pages'] as List? ?? [])
          .map((a) => Map<String, dynamic>.from(a as Map))
          .toList()
      ..additionalCss = v['additional_css'] as String? ?? ''
      ..additionalCssBase = v['additional_css_base'] as String? ?? ''
      ..cssFontPermissions = (v['css_font_permissions'] as List? ?? const [])
          .cast<String>()
      ..additionalCssBundle = (v['additional_css_bundle'] as Map?)
          ?.cast<String, dynamic>()
      ..paragraphIndent = (v['paragraph_indent'] as num? ?? 2.0).toDouble()
      ..paragraphSpacing = (v['paragraph_spacing'] as num? ?? 0.5).toDouble()
      ..marginTop = (v['margin_top'] as num? ?? 0.0).toDouble()
      ..marginTopUnit = v['margin_top_unit'] as String? ?? 'em'
      ..marginRight = (v['margin_right'] as num? ?? 0.0).toDouble()
      ..marginRightUnit = v['margin_right_unit'] as String? ?? 'em'
      ..marginBottom = (v['margin_bottom'] as num? ?? 0.0).toDouble()
      ..marginBottomUnit = v['margin_bottom_unit'] as String? ?? 'em'
      ..marginLeft = (v['margin_left'] as num? ?? 0.0).toDouble()
      ..marginLeftUnit = v['margin_left_unit'] as String? ?? 'em'
      ..visibleToc = v['visible_toc'] as bool? ?? false
      ..chapterNavigation = v['chapter_navigation'] as bool? ?? false
      ..includeToc = v['include_toc'] as bool
      ..illustrations = (v['illustrations'] as List)
          .map((x) => Map<String, dynamic>.from(x as Map))
          .toList();
    return d;
  }

  /// Validates with Rust and stages all decoded values without publishing them.
  /// The returned change must be validated before mutation and published inside
  /// one synchronous change() call, together with any other prepared domains.
  Future<PreparedStateChange> prepareCommit(ProductionPreview preview) async {
    if (!_stillCurrent(preview)) {
      throw const FormatException('制作计划已过期。');
    }
    final result = await productionRequest(
      preview.request,
      apply: true,
      planId: preview.result['plan_id'] as String,
      confirmed: true,
    );
    if (!_stillCurrent(preview)) {
      throw const FormatException('制作计划已过期。');
    }
    final items = (result['items'] as List).cast<Map>();
    final drafts = <String, BookDraft>{};
    final histories = <String, Map<String, dynamic>>{};
    final issues = <String, List<Map<String, dynamic>>>{};
    var count = 0;
    for (final item in items) {
      final id = item['book_id'] as String;
      final v = item['after'] as Map;
      final book = _core.shelf.books.firstWhere((b) => b.id == id);
      final d = draftFromProduction(book, v, this.drafts[id]?.epubResources);

      drafts[id] = d;
      histories[id] = Map<String, dynamic>.from(item['history'] as Map);
      issues[id] = (item['resource_issues'] as List? ?? [])
          .cast<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
      if ((item['changed_fields'] as List).isNotEmpty) count++;
    }
    final expected = ((jsonDecode(preview.request) as Map)['targets'] as List)
        .cast<Map>()
        .map((v) => v['book_id'] as String)
        .toSet();
    if (drafts.length != expected.length ||
        !expected.every(drafts.containsKey)) {
      throw const FormatException('制作结果不完整，本批未应用。');
    }
    var consumed = false;
    return PreparedStateChange(
      () {
        if (consumed || !_stillCurrent(preview)) {
          throw const FormatException('制作计划已过期。');
        }
      },
      () {
        consumed = true;
        this.drafts.addAll(drafts);
        this.histories.addAll(histories);
        for (final entry in drafts.entries) {
          _core.metadata[entry.key] = (
            entry.value.title.trim(),
            entry.value.author.trim(),
          );
          resourceIssues.remove(entry.key);
          if (issues[entry.key]!.isNotEmpty) {
            resourceIssues[entry.key] = issues[entry.key]!;
          }
        }
        batchStatus =
            '制作设置已应用：更新 $count 本，保留 ${items.length - count} 本。${resourceIssues.isEmpty ? '' : '存在待重新定位的资源，制作前请处理。'}';
      },
    );
  }

  Future<bool> confirm(ProductionPreview preview) async {
    if (busy || !_stillCurrent(preview)) {
      _core.change(() => batchStatus = '书稿或制作设置已改变，请重新预览。');
      return false;
    }
    _core.change(() => busy = true);
    try {
      final prepared = await prepareCommit(preview);
      prepared.validate();
      _core.change(prepared.publish);
      return true;
    } catch (error) {
      _core.change(
        () => batchStatus = error is FormatException
            ? error.message.toString()
            : '制作资源无效或计划已过期，未应用，请重新检查。',
      );
      return false;
    } finally {
      _core.change(() => busy = false);
    }
  }
}
