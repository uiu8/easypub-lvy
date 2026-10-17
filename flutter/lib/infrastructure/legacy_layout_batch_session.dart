import '../application/layout_batch_service.dart';
import '../application/layout_service.dart';
import '../application/book_information_service.dart';
import '../prototype/prototype_state.dart';

class LegacyLayoutBatchSession implements LayoutBatchSession {
  LegacyLayoutBatchSession(this.backend, this.bookId)
    : source = Map.unmodifiable({
        for (final key in layoutFields)
          key: backend.production.settings(bookId)[key],
      }),
      sourceGuard = backend.publicationContext(bookId);
  final PrototypeState backend;
  final String bookId, sourceGuard;
  @override
  final Map<String, Object?> source;
  bool disposed = false;
  int generation = 0;
  Map<String, String> guards = {};
  ProductionPreview? pending;
  LayoutBatchPreview? exposed;
  void check(int ticket) {
    if (disposed ||
        ticket != generation ||
        backend.projectBusy ||
        backend.production.busy ||
        backend.importing ||
        backend.publicationContext(bookId) != sourceGuard ||
        !guards.entries.every(
          (e) => backend.publicationContext(e.key) == e.value,
        )) {
      throw const FormatException('书稿或项目已改变，请关闭窗口后重新预览。');
    }
  }

  @override
  Future<LayoutBatchPreview> preview(
    Set<String> fields,
    List<String> targets,
  ) async {
    final ticket = ++generation;
    pending = null;
    exposed = null;
    guards = {};
    check(ticket);
    final keys = Set<String>.of(fields);
    if (keys.contains('font_size') || keys.contains('font_size_unit')) {
      keys.addAll({'font_size', 'font_size_unit'});
    }
    final ids = List<String>.of(targets);
    if (keys.isEmpty ||
        keys.any((key) => !layoutFields.contains(key)) ||
        ids.isEmpty ||
        ids.toSet().length != ids.length) {
      throw const FormatException('请选择排版字段和不重复的目标书稿。');
    }
    guards = {for (final id in ids) id: backend.publicationContext(id)};
    final result = await backend.production.previewChanges(
      {
        for (final id in ids)
          id: {
            'op': 'patch',
            'fields': {
              for (final key in keys) key: {'op': 'set', 'value': source[key]},
            },
          },
      },
      additionalGuards: {bookId},
    );
    check(ticket);
    final items = <String, BookInformationPreview>{};
    for (final row in (result.result['items'] as List).cast<Map>()) {
      items[row['book_id'] as String] = BookInformationPreview(
        Map<String, Object?>.from(row['before'] as Map),
        Map<String, Object?>.from(row['after'] as Map),
        (row['changed_fields'] as List).cast<String>(),
      );
    }
    if (items.length != ids.length || !ids.every(items.containsKey)) {
      throw const FormatException('批量预览不完整，本批未应用。');
    }
    final plan = LayoutBatchPreview(items);
    pending = result;
    exposed = plan;
    return plan;
  }

  @override
  Future<void> apply(LayoutBatchPreview preview) async {
    check(generation);
    if (!identical(exposed, preview) || pending == null) {
      throw const FormatException('请重新预览。');
    }
    final plan = pending!;
    pending = null;
    exposed = null;
    if (!await backend.production.confirm(plan)) {
      throw FormatException(backend.production.batchStatus);
    }
    disposed = true;
  }

  @override
  void dispose() {
    disposed = true;
    generation++;
    pending = null;
    exposed = null;
  }
}
