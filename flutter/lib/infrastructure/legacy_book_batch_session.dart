import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/book_batch_service.dart';
import '../application/book_information_service.dart';
import '../application/layout_service.dart';
import '../application/cleanup_batch_service.dart';
import '../prototype/prototype_state.dart';
import 'legacy_cleanup_batch_session.dart';

class LegacyBookBatchSession implements BookBatchSession {
  @override
  Listenable get changes => backend;
  @override
  bool canRead(BookBatchPreview plan, String target) {
    try {
      check(generation);
      return identical(plan, exposed) &&
          plan.cleanup != null &&
          cleanupSession.canRead(plan.cleanup!, target);
    } catch (_) {
      return false;
    }
  }

  LegacyBookBatchSession(this.backend, this.bookId)
    : sourceContext = backend.publicationContext(bookId),
      cleanupSession = LegacyCleanupBatchSession(backend, bookId);
  final PrototypeState backend;
  final String bookId, sourceContext;
  final LegacyCleanupBatchSession cleanupSession;
  bool disposed = false;
  int generation = 0;
  Map<String, String> guards = {};
  ProductionPreview? production;
  BookBatchPreview? exposed;
  static final allowed = {
    ...layoutFields,
    ...bookInformationFields.keys,
    'cover',
  };
  void check(int ticket) {
    if (disposed ||
        ticket != generation ||
        backend.projectBusy ||
        backend.importing ||
        backend.production.busy ||
        backend.cleanup.historyBusy ||
        backend.publicationContext(bookId) != sourceContext ||
        !guards.entries.every(
          (e) => backend.publicationContext(e.key) == e.value,
        )) {
      throw const FormatException('书稿或项目已变化，本批未应用，请重新打开批量窗口。');
    }
  }

  @override
  Future<BookBatchPreview> preview(
    Set<String> fields,
    List<String> targets, {
    required bool cleanup,
    required bool append,
  }) async {
    final ticket = ++generation;
    production = null;
    exposed = null;
    guards = {};
    cleanupSession.cancel();
    check(ticket);
    final keys = Set<String>.of(fields), ids = List<String>.of(targets);
    if ((keys.isEmpty && !cleanup) ||
        keys.any((k) => !allowed.contains(k)) ||
        ids.isEmpty ||
        ids.toSet().length != ids.length) {
      throw const FormatException('请选择明确字段或清理规则，以及不重复的目标书。');
    }
    guards = {for (final id in ids) id: backend.publicationContext(id)};
    CleanupBatchPreview? cleaning;
    final errors = <String, String>{};
    var batchError = '';
    if (cleanup) {
      final template = backend.cleanup.drafts[bookId];
      if (template == null) throw const FormatException('当前书没有已保存的清理规则。');
      cleaning = await cleanupSession.preview(
        jsonEncode(template),
        ids,
        append: append,
      );
      check(ticket);
      for (final item in cleaning.items) {
        if (item.error.isNotEmpty) errors[item.bookId] = '文本清理：${item.error}';
      }
    }
    final values = backend.production.settings(bookId);
    final expanded = {...keys}..remove('cover');
    if (keys.contains('font_size') || keys.contains('font_size_unit')) {
      expanded.addAll({'font_size', 'font_size_unit'});
    }
    if (keys.contains('cover')) {
      expanded.addAll({
        'cover_path',
        'cover_fit',
        'cover_crop',
        'cover_design',
      });
    }
    final items = <String, BookInformationPreview>{};
    if (expanded.isNotEmpty) {
      final changes = <String, Map<String, dynamic>>{
        for (final id in ids)
          id: {
            'op': 'patch',
            'fields': {
              for (final key in expanded)
                key: values[key] == null
                    ? {'op': 'clear'}
                    : {'op': 'set', 'value': values[key]},
            },
          },
      };
      void collect(ProductionPreview result) {
        for (final row in (result.result['items'] as List).cast<Map>()) {
          items[row['book_id'] as String] = BookInformationPreview(
            Map<String, Object?>.from(row['before'] as Map),
            Map<String, Object?>.from(row['after'] as Map),
            (row['changed_fields'] as List).cast<String>(),
          );
        }
      }

      try {
        final result = await backend.production.previewChanges(
          changes,
          additionalGuards: {bookId},
        );
        check(ticket);
        collect(result);
        if (items.length != ids.length || !ids.every(items.containsKey)) {
          throw const FormatException('制作预览不完整，本批未应用。');
        }
        production = result;
      } catch (_) {
        check(ticket);
        items.clear();
        // Only diagnose per book on a failed batch. Single-book results can
        // never substitute for the original batch commit token.
        for (final id in ids) {
          try {
            final single = await backend.production.previewChanges(
              {id: changes[id]!},
              additionalGuards: {bookId},
            );
            check(ticket);
            collect(single);
          } catch (_) {
            check(ticket);
            errors[id] = [
              if (errors[id] != null) errors[id]!,
              '制作设置或关联资源未通过校验，请检查书籍信息、排版及资源。',
            ].join('\n');
          }
        }
        batchError = '整批制作预览失败，以上逐书结果仅用于定位问题；请返回选择后重新预览。';
      }
    }
    final plan = BookBatchPreview(
      items,
      cleaning,
      errors: errors,
      batchError: batchError,
    );
    exposed = plan;
    return plan;
  }

  @override
  Future<CleanupBatchDifferencePage> differences(
    BookBatchPreview plan,
    String bookId, {
    int offset = 0,
  }) {
    check(generation);
    if (!identical(plan, exposed) || plan.cleanup == null) {
      throw const FormatException('请重新预览清理规则。');
    }
    return cleanupSession.differences(plan.cleanup!, bookId, offset: offset);
  }

  @override
  Future<void> apply(BookBatchPreview plan) async {
    final ticket = generation;
    check(ticket);
    if (!identical(plan, exposed) || !plan.ready) {
      throw const FormatException('本批有未通过项，请处理后重新预览。');
    }
    exposed = null;
    final prepared = <PreparedStateChange>[];
    if (plan.cleanup != null) {
      prepared.add(await cleanupSession.prepareCommit(plan.cleanup!));
    }
    check(ticket);
    if (production != null) {
      prepared.add(await backend.production.prepareCommit(production!));
    }
    check(ticket);
    for (final change in prepared) {
      change.validate();
    }
    // No awaits, callbacks or notifications between domain publications.
    backend.change(() {
      for (final change in prepared) {
        change.publish();
      }
    });
    disposed = true;
  }

  @override
  void dispose() {
    disposed = true;
    generation++;
    exposed = null;
    production = null;
    cleanupSession.dispose();
  }
}
