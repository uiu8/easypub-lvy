import 'dart:io';

import '../src/rust/api.dart' as api;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/book_information_service.dart';
import '../prototype/prototype_state.dart';

class LegacyBookInformationSession implements BookInformationSession {
  LegacyBookInformationSession(this.backend, this.bookId) {
    _guard = guard();
  }
  final PrototypeState backend;
  final String bookId;
  late String _guard;
  bool disposed = false;
  int generation = 0;
  ProductionPreview? pending;
  BookInformationPreview? exposed;
  static final fields = {
    ...bookInformationFields.keys,
    'cover_path',
    'cover_fit',
    'cover_crop',
    'cover_design',
  };
  Set<String> get allowedFields => fields;
  String guard() {
    final source = backend.shelf.books
        .firstWhere((b) => b.id == bookId && !b.isDemo)
        .source!;
    return jsonEncode([
      source.sourceId,
      source.revision,
      backend.production.settings(bookId),
      backend.production.histories[bookId],
    ]);
  }

  void fresh() {
    if (disposed ||
        backend.projectBusy ||
        backend.production.busy ||
        guard() != _guard) {
      throw const FormatException('书稿或制作设置已改变，请恢复已保存值后重新编辑。');
    }
  }

  @override
  Future<CoverImageEvidence> storeGeneratedCover(Uint8List bytes) async {
    fresh();
    if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('生成封面大小不符合限制。');
    }
    final root = Directory(
      '${backend.settingsDirectory ?? '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}/EasyPub-RustFlutter/settings'}/generated-covers',
    );
    await root.create(recursive: true);
    final directory = await root.createTemp('cover-');
    final file = File('${directory.path}/cover.png');
    try {
      await file.writeAsBytes(bytes, flush: true);
      final result = await inspectImage(file.absolute.path);
      if (result.width != 1200 ||
          result.height != 1600 ||
          result.format != 'png') {
        throw const FormatException('文字封面应为1200×1600 PNG。');
      }
      return result;
    } catch (_) {
      if (await file.exists()) await file.delete();
      await directory.delete();
      rethrow;
    }
  }

  @override
  Future<CoverImageEvidence> inspectImage(String path) async {
    fresh();
    final result = jsonDecode(await api.inspectImageText(path: path)) as Map;
    fresh();
    return CoverImageEvidence(
      result['path'] as String,
      result['sha256'] as String,
      result['width'] as int,
      result['height'] as int,
      result['bytes'] as int,
      result['format'] as String,
    );
  }

  @override
  Listenable get changes => backend;
  @override
  String? get styleCoverBackground {
    if (disposed) return null;
    final style = backend.production.settings(bookId)['chapter_style'];
    return style is Map ? style['cover_background'] as String? : null;
  }

  @override
  Map<String, Object?> get saved {
    if (disposed) throw const FormatException('书籍信息已关闭。');
    _guard = guard();
    pending = null;
    exposed = null;
    generation++;
    final values = backend.production.settings(bookId);
    return Map.unmodifiable({
      for (final key in allowedFields) key: values[key],
    });
  }

  @override
  Future<BookInformationPreview> preview(Map<String, Object?> values) async {
    fresh();
    if (values.keys.any((key) => !allowedFields.contains(key))) {
      throw const FormatException('包含不支持的书籍信息字段。');
    }
    return previewChange({
      'op': 'patch',
      'fields': {
        for (final entry in values.entries)
          entry.key: entry.value == null
              ? {'op': 'clear'}
              : {'op': 'set', 'value': entry.value},
      },
    });
  }

  Future<BookInformationPreview> previewChange(
    Map<String, Object?> change,
  ) async {
    fresh();
    final ticket = ++generation;
    pending = null;
    exposed = null;
    final result = await backend.production.previewChanges({bookId: change});
    fresh();
    if (ticket != generation) throw const FormatException('预览已取消或被替代。');
    final row = (result.result['items'] as List).single as Map;
    final next = BookInformationPreview(
      Map<String, Object?>.from(row['before'] as Map),
      Map<String, Object?>.from(row['after'] as Map),
      [
        for (final key in (row['changed_fields'] as List).cast<String>())
          if (key != 'metadata_origins') key,
        for (final key
            in ((row['after'] as Map)['metadata_origins'] as Map? ?? {}).keys
                .cast<String>())
          if (jsonEncode(
                    ((row['before'] as Map)['metadata_origins'] as Map? ??
                        {})[key],
                  ) !=
                  jsonEncode(
                    ((row['after'] as Map)['metadata_origins'] as Map)[key],
                  ) &&
              !(row['changed_fields'] as List).contains(key))
            key,
      ],
    );
    pending = result;
    exposed = next;
    return next;
  }

  @override
  Future<void> apply(BookInformationPreview preview) async {
    fresh();
    if (!identical(preview, exposed) || pending == null) {
      throw const FormatException('请重新预览并确认。');
    }
    final plan = pending!;
    pending = null;
    exposed = null;
    if (!await backend.production.confirm(plan)) {
      throw FormatException(backend.production.batchStatus);
    }
    _guard = guard();
  }

  @override
  void dispose() {
    disposed = true;
    generation++;
    pending = null;
    exposed = null;
  }
}
