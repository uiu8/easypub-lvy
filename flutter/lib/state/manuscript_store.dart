// 章节结构、人工编辑、识别规则草稿、问题审阅与有效书稿的章节修改历史（V20 从 PrototypeState 拆出）。
// 只通过 PrototypeState 的公开接口读写书库、清理与制作设置；行为与拆分前相同。
import 'dart:convert';

import '../application/cleanup_service.dart'
    show CleanupSkippedEdit, cleanupCheckpointMessage, describeSkippedEdits;
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class ManuscriptStore {
  ManuscriptStore(this._core);
  final PrototypeState _core;

  final effectiveHistories = <String, Map<String, dynamic>>{};

  final structureHistories = <String, Map<String, dynamic>>{};

  final structures = <String, Map<String, dynamic>>{};

  final recognitionDrafts = <String, Map<String, dynamic>>{};

  List<Map<String, dynamic>> recognitionPresets = [];

  final findingReviews = <String, Map<String, dynamic>>{};

  final manualEditDrafts = <String, Map<String, dynamic>>{};

  Map<String, dynamic> effectiveBase(String bookId) {
    final draft = manualEditDrafts[bookId];
    final actions = draft == null
        ? []
        : draft['history'][draft['cursor']] as List;
    return {
      'structure': structures[bookId],
      'manual': actions.isEmpty
          ? null
          : {'kind': 'manual_batch', 'actions': actions},
      'cleanup': _core.cleanup.drafts[bookId],
    };
  }

  Map<String, dynamic>? effectiveSelection(String bookId) {
    final history = effectiveHistories[bookId];
    if (history == null) return null;
    final request = (history['history'][history['cursor']]['request'] as Map)
        .cast<String, dynamic>();
    return (request['actions'] as List).isEmpty && request['checkpoint'] == null
        ? null
        : request;
  }

  /// 当前章节修改基于检查点时，创建该检查点那一步保存的原始操作（CLEAN-105）；
  /// 清理预览带上它才能换算。没有检查点或找不到时为 null。
  Map<String, dynamic>? effectiveCheckpointRoot(String bookId) {
    final history = effectiveHistories[bookId];
    if (history == null) return null;
    final states = (history['history'] as List).cast<Map>();
    final checkpoint =
        (states[history['cursor'] as int]['request'] as Map)['checkpoint'];
    if (checkpoint == null) return null;
    final key = jsonEncode(checkpoint);
    for (final state in states) {
      final request = state['request'] as Map;
      if (request['checkpoint'] != null &&
          jsonEncode(request['checkpoint']) == key &&
          state['recorded_request'] != null) {
        return (state['recorded_request'] as Map).cast<String, dynamic>();
      }
    }
    return null;
  }

  /// Moves the chapter edits onto [base] (normally a changed cleanup) as a new
  /// undoable history state. Does not store it; returns null without edits.
  Future<
    ({
      Map<String, dynamic> history,
      int kept,
      int skipped,
      List<CleanupSkippedEdit> skippedEdits,
    })?
  >
  rebaseEffectiveHistory(String bookId, Map<String, dynamic> base) async {
    if (effectiveSelection(bookId) == null) return null;
    final book = _core.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final String text;
    try {
      text = await api.editEffectiveDraft(
        sourceId: book.source!.sourceId,
        revision: book.source!.revision,
        baseJson: jsonEncode(base),
        draftJson: jsonEncode(effectiveHistories[bookId]),
        commandJson: jsonEncode({'op': 'rebase'}),
      );
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      if (detail['next_action'] == 'rebase_checkpoint') {
        throw const FormatException(cleanupCheckpointMessage);
      }
      rethrow;
    }
    final result = jsonDecode(text) as Map;
    final summary = result['rebase'] as Map;
    return (
      history: (result['history'] as Map).cast<String, dynamic>(),
      kept: (summary['kept'] as List).length,
      skipped: (summary['skipped'] as List).length,
      skippedEdits: describeSkippedEdits(summary['skipped'] as List),
    );
  }

  /// Validate a full candidate before changing any domain's active history.
  /// Archived stale history remains recoverable; it is never silently discarded.
  Future<void> validateEffectiveBase(
    String bookId,
    Map<String, dynamic> base,
  ) async {
    final book = _core.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final guard = _core.publicationContext(bookId);
    try {
      await api.effectiveStructureText(
        sourceId: book.source!.sourceId,
        revision: book.source!.revision,
        settingsJson: base['structure'] == null
            ? ''
            : jsonEncode(base['structure']),
        selectedJson: jsonEncode({
          'kind': 'publication',
          if (base.containsKey('catalog')) 'catalog': base['catalog'],
          'manual': base['manual'],
          'cleanup': base['cleanup'],
          'post_edits': effectiveSelection(bookId),
        }),
        offset: 0,
      );
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      if (detail['error'] == 'InvalidRule' &&
          detail['operation'] == 'effective_edit') {
        throw const FormatException(
          '后续章节编辑依赖当前清理或结构。请先在章节或变更记录中撤销这些编辑，再更改前序操作；草稿和历史均已保留。',
        );
      }
      rethrow;
    }
    if (guard != _core.publicationContext(bookId)) {
      throw const FormatException('书稿已变化，候选方案未应用，请重新操作。');
    }
  }

  Future<Map<String, dynamic>> effectiveTree(
    String bookId,
    int offset, {
    bool includeEdits = true,
    String? previewNodeId,
    int previewOffset = 0,
    bool previewPageBody = false,
    bool outline = false,
    bool statistics = false,
  }) async {
    final book = _core.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final guard = _core.publicationContext(bookId);
    final base = effectiveBase(bookId);
    final raw = await api.effectiveStructureText(
      sourceId: book.source!.sourceId,
      revision: book.source!.revision,
      settingsJson: base['structure'] == null
          ? ''
          : jsonEncode(base['structure']),
      selectedJson: jsonEncode({
        'kind': 'publication',
        if (statistics) 'statistics': true,
        if (outline) 'outline': true,
        if (previewNodeId != null || previewPageBody)
          'body_preview': {
            'entry_id': previewNodeId,
            'offset': previewOffset,
            if (previewPageBody) 'select_page': true,
            if (previewPageBody && previewNodeId != null) 'focus_page': true,
          },
        'manual': base['manual'],
        'cleanup': base['cleanup'],
        'post_edits': includeEdits ? effectiveSelection(bookId) : null,
      }),
      offset: offset,
    );
    if (guard != _core.publicationContext(bookId)) {
      throw const FormatException('书稿已变化，请重新读取。');
    }
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Future<bool> editEffectiveDraft(
    String bookId,
    Map<String, dynamic> command, {
    bool requireMatching = false,
  }) async {
    final book = _core.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final guard = _core.publicationContext(bookId);
    final result = jsonDecode(
      await api.editEffectiveDraft(
        sourceId: book.source!.sourceId,
        revision: book.source!.revision,
        baseJson: jsonEncode(effectiveBase(bookId)),
        draftJson: effectiveHistories[bookId] == null
            ? ''
            : jsonEncode(effectiveHistories[bookId]),
        commandJson: jsonEncode(command),
      ),
    ) as Map;
    if (guard != _core.publicationContext(bookId)) {
      throw const FormatException('书稿已变化，未应用后续编辑。');
    }
    if (requireMatching && result['matches_current'] != true) {
      throw const FormatException('章节依据已改变，请先恢复对应清理、结构或人工编辑版本；当前草稿和历史未改变。');
    }
    _core.change(
      () => effectiveHistories[bookId] = (result['history'] as Map)
          .cast<String, dynamic>(),
    );
    return result['matches_current'] == true;
  }
}
