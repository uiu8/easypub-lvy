// 书库收藏夹的实现（V84，LIB-118–126）：分组存进项目；改书籍信息走制作批处理的
// patch 预览与确认，撤销走每本书制作历史的 undo，都由 Rust 校验。
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../application/book_collection_service.dart';
import '../prototype/folder_scan.dart';
import '../prototype/prototype_state.dart';

class LegacyCollections implements BookCollectionService {
  LegacyCollections(this.backend) {
    _sync();
    backend.addListener(_sync);
  }
  final PrototypeState backend;
  final _collections = ValueNotifier<List<BookCollection>>(const []);
  String _signature = '';

  void dispose() {
    backend.removeListener(_sync);
    _collections.dispose();
  }

  void _sync() {
    final signature = jsonEncode(backend.collections);
    if (signature == _signature) return;
    _signature = signature;
    _collections.value = List.unmodifiable(
      backend.collections.map(BookCollection.fromJson),
    );
  }

  @override
  ValueListenable<List<BookCollection>> get collections => _collections;

  void _write(List<BookCollection> next) {
    if (backend.projectBusy) {
      throw const FormatException('请等待项目操作完成后再改收藏夹。');
    }
    backend.change(
      () => backend.collections = [for (final c in next) c.toJson()],
    );
  }

  BookCollection _find(String id) => _collections.value.firstWhere(
    (c) => c.id == id,
    orElse: () => throw const FormatException('收藏夹已不存在。'),
  );

  void _check(BookCollection c, {String? exceptId}) {
    final error = collectionNameError(
      c.name,
      _collections.value,
      exceptId: exceptId,
    );
    if (error != null) throw FormatException(error);
    if (c.name != c.name.trim()) throw const FormatException('名称首尾不能有空白');
    for (final entry in c.template.entries) {
      final op = entry.value['op'];
      if (!collectionTemplateFields.containsKey(entry.key) ||
          !const {'keep', 'set', 'fill_empty', 'clear'}.contains(op) ||
          ((op == 'set' || op == 'fill_empty') &&
              (entry.value['value'] ?? '').isEmpty)) {
        throw FormatException(
          '${collectionTemplateFields[entry.key] ?? entry.key}的预设无效。',
        );
      }
    }
  }

  @override
  BookCollection createCollection(
    String name, {
    Map<String, Map<String, String>> template = const {},
    bool autoApply = false,
  }) {
    final random = Random.secure();
    final id =
        'c-${List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final created = BookCollection(
      id: id,
      name: name.trim(),
      template: template,
      autoApply: autoApply,
    );
    _check(created);
    _write([..._collections.value, created]);
    return created;
  }

  @override
  void updateCollection(BookCollection collection) {
    final old = _find(collection.id);
    final next = collection.copyWith(
      name: collection.name.trim(),
      books: old.books,
    );
    _check(next, exceptId: next.id);
    _write([for (final c in _collections.value) c.id == next.id ? next : c]);
  }

  @override
  void deleteCollection(String id) {
    _find(id);
    _write([
      for (final c in _collections.value)
        if (c.id != id) c,
    ]);
  }

  Set<String> get _bookIds => {
    for (final b in backend.shelf.books)
      if (!b.isDemo) b.id,
  };

  @override
  List<String> addToCollection(String id, Iterable<String> bookIds) {
    final c = _find(id);
    final known = _bookIds;
    final added = [
      for (final b in {...bookIds})
        if (known.contains(b) && !c.books.contains(b)) b,
    ];
    if (added.isEmpty) return const [];
    _write([
      for (final x in _collections.value)
        x.id == id ? x.copyWith(books: [...x.books, ...added]) : x,
    ]);
    return added;
  }

  @override
  void removeFromCollection(String id, Iterable<String> bookIds) {
    final c = _find(id);
    final drop = bookIds.toSet();
    if (!c.books.any(drop.contains)) return;
    _write([
      for (final x in _collections.value)
        x.id == id
            ? x.copyWith(
                books: [
                  for (final b in x.books)
                    if (!drop.contains(b)) b,
                ],
              )
            : x,
    ]);
  }

  @override
  String? bookIdForPath(String path) {
    final key = folderImportPathKey(path);
    for (final b in backend.shelf.books) {
      if (b.isDemo || b.source == null) continue;
      final source = b.source!.originPath ?? b.source!.path;
      if (folderImportPathKey(source) == key) return b.id;
    }
    return null;
  }

  @override
  List<String> knownCategories() {
    final counts = <String, int>{};
    for (final id in _bookIds) {
      final value = '${backend.production.settings(id)['category'] ?? ''}'
          .trim();
      if (value.isNotEmpty) counts[value] = (counts[value] ?? 0) + 1;
    }
    return counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }

  ProductionPreview? _pending;
  BookFieldPreview? _exposed;

  void _idle() {
    if (backend.projectBusy || backend.production.busy || backend.importing) {
      throw const FormatException('请等待当前操作完成后再改书籍信息。');
    }
  }

  @override
  Future<BookFieldPreview> previewFields(
    Map<String, Map<String, String>> fields,
    List<String> bookIds, {
    String label = '',
  }) async {
    _idle();
    _pending = null;
    _exposed = null;
    final edits = <String, Map<String, String>>{
      for (final e in fields.entries)
        if (e.value['op'] != 'keep')
          e.key: {
            'op': e.value['op']!,
            if (e.value['op'] == 'set' || e.value['op'] == 'fill_empty')
              'value': e.value['value'] ?? '',
          },
    };
    final known = _bookIds;
    final targets = [
      for (final id in {...bookIds})
        if (known.contains(id)) id,
    ];
    if (edits.isEmpty || targets.isEmpty) {
      throw const FormatException('没有需要改的字段或书籍。');
    }
    final plan = await backend.production.previewChanges({
      for (final id in targets) id: {'op': 'patch', 'fields': edits},
    });
    final titles = {
      for (final b in backend.shelf.books) b.id: backend.displayTitle(b),
    };
    final items = [
      for (final raw in (plan.result['items'] as List).cast<Map>())
        BookFieldChange(
          bookId: raw['book_id'] as String,
          title: titles[raw['book_id']] ?? '',
          before: Map.unmodifiable(
            Map<String, Object?>.from(raw['before'] as Map),
          ),
          after: Map.unmodifiable(
            Map<String, Object?>.from(raw['after'] as Map),
          ),
          changed: List.unmodifiable([
            for (final key in (raw['changed_fields'] as List).cast<String>())
              if (collectionTemplateFields.containsKey(key)) key,
          ]),
        ),
    ];
    final preview = BookFieldPreview(items, label: label);
    _pending = plan;
    _exposed = preview;
    return preview;
  }

  @override
  Future<BookFieldApplied> applyFields(BookFieldPreview preview) async {
    _idle();
    if (!identical(preview, _exposed) || _pending == null) {
      throw const FormatException('预览已失效，请重新预览。');
    }
    final plan = _pending!;
    _pending = null;
    _exposed = null;
    if (!await backend.production.confirm(plan)) {
      throw FormatException(backend.production.batchStatus);
    }
    final changed = [
      for (final i in preview.items)
        if (i.changed.isNotEmpty) i.bookId,
    ];
    return BookFieldApplied(
      {for (final id in changed) id: backend.production.guardFor(id)},
      changed,
      changed.isEmpty ? '书籍信息已是预设值，没有改动。' : '已更新 ${changed.length} 本书的书籍信息。',
    );
  }

  @override
  Future<String> undoFields(BookFieldApplied applied) async {
    _idle();
    final guards = applied.token as Map<String, String>;
    if (guards.isEmpty) return '没有需要撤销的改动。';
    for (final entry in guards.entries) {
      if (!_bookIds.contains(entry.key) ||
          backend.production.guardFor(entry.key) != entry.value) {
        throw const FormatException('之后又改过其中的书，不能整批撤销；请到书籍信息里逐本撤销。');
      }
    }
    final plan = await backend.production.previewChanges({
      for (final id in guards.keys) id: {'op': 'undo'},
    });
    if (!await backend.production.confirm(plan)) {
      throw FormatException(backend.production.batchStatus);
    }
    return '已撤销 ${guards.length} 本书的信息改动。';
  }
}
