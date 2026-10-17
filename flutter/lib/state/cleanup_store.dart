// 文本清理的设置、历史与批量（V20 从 PrototypeState 拆出，原 cleanupDrafts 等）。
// 只通过 PrototypeState 的公开接口读写书库与章节修改；行为与拆分前相同。
import 'dart:convert';

import '../application/cleanup_service.dart' show CleanupEditsNeedConfirmation;
import '../prototype/cleanup_error.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class CleanupStore {
  CleanupStore(this._core);
  final PrototypeState _core;

  List<int> boundaryLines(String bookId) => [
    for (final row
        in (_core.manuscript.structures[bookId]?['overrides'] as List? ?? []))
      if (row['role'] != 'body') row['source_line'] as int,
  ];
  final drafts = <String, Map<String, dynamic>>{};
  final histories = <String, Map<String, dynamic>>{};
  final historyStatus = <String, String>{};
  bool historyBusy = false;
  String batchStatus = '';

  Map<String, dynamic> batchRequest(
    String templateBookId,
    List<String> targetIds,
    bool append, {
    Map<String, dynamic>? templateOverride,
  }) {
    final template = templateOverride ?? drafts[templateBookId];
    if (template == null ||
        targetIds.isEmpty ||
        targetIds.toSet().length != targetIds.length) {
      throw const FormatException('请先保存当前书清理设置，并选择目标书目。');
    }
    return {
      'template': template,
      'append': append,
      'targets': [
        for (final id in targetIds)
          (() {
            final b = _core.shelf.books
                .where((b) => b.id == id && !b.isDemo)
                .firstOrNull;
            if (b == null) throw const FormatException('目标书目已改变，请重新选择。');
            return {
              'book_id': id,
              'source_id': b.source!.sourceId,
              'revision': b.source!.revision,
              'current': drafts[id],
              'history': histories[id],
              'protected_lines': boundaryLines(id),
            };
          })(),
      ],
    };
  }

  /// 改变清理历史（设置、撤销、重做）。已有章节修改时，把它们换算到新的清理结果上，
  /// 作为章节历史中的新一步（CLEAN-103）；有无法换算的修改且未 [dropSkipped] 时
  /// 抛出 [CleanupEditsNeedConfirmation]，由界面列出并请用户确认，不改变任何状态。
  Future<bool> editSettings(
    String bookId,
    Map<String, dynamic> command, {
    bool dropSkipped = false,
  }) async {
    final book = _core.shelf.books.where((b) => b.id == bookId).firstOrNull;
    final source = book?.source;
    if (source == null || historyBusy || _core.projectBusy || _core.importing) {
      return false;
    }
    final guard = _core.publicationContext(bookId);
    final old =
        histories[bookId] ??
        {
          'source_id': source.sourceId,
          'source_revision': source.revision,
          'history': [null, if (drafts[bookId] != null) drafts[bookId]],
          'cursor': drafts[bookId] == null ? 0 : 1,
        };
    _core.change(() => historyBusy = true);
    try {
      final next = jsonDecode(
        await api.editCleanupDraft(
          sourceId: source.sourceId,
          revision: source.revision,
          draftJson: jsonEncode(old),
          commandJson: jsonEncode(command),
        ),
      ) as Map<String, dynamic>;
      if (!_core.shelf.books.any(
        (b) => b.id == bookId && b.source?.sourceId == source.sourceId,
      )) {
        return false;
      }
      final candidate = (next['history'] as List)[next['cursor'] as int];
      final nextBase = {..._core.manuscript.effectiveBase(bookId), 'cleanup': candidate};
      // 有章节修改时换算到新的清理结果上；没有时只核对新依据能否组成书稿。
      final rebased = _core.manuscript.effectiveSelection(bookId) == null
          ? null
          : await _core.manuscript.rebaseEffectiveHistory(bookId, nextBase);
      if (rebased == null) await _core.manuscript.validateEffectiveBase(bookId, nextBase);
      if (guard != _core.publicationContext(bookId)) {
        throw const FormatException('书稿已变化，清理历史未更改，请重新操作。');
      }
      if (rebased != null && rebased.skipped > 0 && !dropSkipped) {
        final before = histories[bookId];
        throw CleanupEditsNeedConfirmation(
          redo: command['op'] == 'redo',
          kept: rebased.kept,
          skipped: rebased.skippedEdits,
          proceed: () async {
            if (guard != _core.publicationContext(bookId) ||
                !identical(before, histories[bookId])) {
              throw const FormatException('书稿或清理历史已变化，未作更改，请重新操作。');
            }
            if (!await editSettings(bookId, command, dropSkipped: true)) {
              throw FormatException(historyStatus[bookId] ?? '清理历史未能更改，原设置保留。');
            }
          },
        );
      }
      _core.change(() {
        if (rebased != null) _core.manuscript.effectiveHistories[bookId] = rebased.history;
        histories[bookId] = next;
        final current = (next['history'] as List)[next['cursor'] as int];
        if (current == null) {
          drafts.remove(bookId);
        } else {
          drafts[bookId] = (current as Map).cast<String, dynamic>();
        }
        historyStatus[bookId] =
            (current == null
                ? '本书清理已停用，可撤销恢复。已输出文件不变。'
                : '清理设置已保存到本书；另存项目可保留历史。输出前须重新预览确认。') +
            (rebased == null || rebased.kept + rebased.skipped == 0
                ? ''
                : '${rebased.kept} 处章节修改已换算到新的文本'
                      '${rebased.skipped > 0 ? '，放弃 ${rebased.skipped} 处' : ''}。');
      });
      return true;
    } on CleanupEditsNeedConfirmation {
      rethrow;
    } catch (error) {
      final message = await cleanupErrorMessage(
        error,
        '无法更改清理设置，请检查规则、历史和原稿版本；原设置已保留。',
      );
      _core.change(() => historyStatus[bookId] = message);
      return false;
    } finally {
      _core.change(() => historyBusy = false);
    }
  }
}
