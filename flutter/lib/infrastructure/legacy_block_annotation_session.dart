import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/block_annotation_service.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class LegacyBlockAnnotationSession implements BlockAnnotationSession {
  LegacyBlockAnnotationSession(this.backend, this.bookId);
  final PrototypeState backend;
  final String bookId;
  final _issued = Expando<ProductionPreview>();
  bool _disposed = false;
  @override
  Listenable get changes => backend;

  void _ready() {
    if (_disposed ||
        backend.projectBusy ||
        backend.production.busy ||
        !backend.shelf.books.any((b) => b.id == bookId && !b.isDemo)) {
      throw const BlockAnnotationException('block_annotation_stale');
    }
  }

  Future<ProductionPreview> _invoke(Map<String, Object?> action) async {
    _ready();
    final guard = backend.production.guardFor(bookId);
    final context = backend.illustrationContext(bookId);
    final publication = backend.publicationRequest(bookId);
    final current = publication['settings'];
    final request = jsonEncode({
      'op': 'block_annotations',
      'publication': publication,
      'action': action,
      'targets': [
        {
          'book_id': bookId,
          'current': current,
          'history':
              backend.production.histories[bookId] ??
              {
                'source_id': publication['source_id'],
                'revision': publication['revision'],
                'states': [current],
                'cursor': 0,
              },
          'change': {'op': 'inspect'},
        },
      ],
    });
    try {
      final result = await backend.production.productionRequest(request);
      _ready();
      if (guard != backend.production.guardFor(bookId) ||
          context != backend.illustrationContext(bookId)) {
        throw const BlockAnnotationException('block_annotation_stale');
      }
      return ProductionPreview(request, result, {bookId: guard})
        ..compositionGuards[bookId] = context;
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      throw BlockAnnotationException(detail['next_action'] as String);
    }
  }

  @override
  Future<BlockAnnotationSnapshot> list() async =>
      BlockAnnotationSnapshot.fromJson(
        (await _invoke({'kind': 'list'})).result['block_annotations'] as Map,
      );

  @override
  Future<BlockAnnotationRange> resolveLines(
    BlockAnnotationSnapshot snapshot, {
    required String entryId,
    required int firstLine,
    required int lastLine,
  }) async {
    final result = await _invoke({
      'kind': 'resolve_lines',
      'entry_id': entryId,
      'first_line': firstLine,
      'last_line': lastLine,
      'content_id': snapshot.contentId,
    });
    final range = result.result['selection'] as Map;
    return BlockAnnotationRange(range['start'] as int, range['end'] as int);
  }

  Future<BlockAnnotationPreview> _preview(Map<String, Object?> action) async {
    final pending = await _invoke(action);
    final exposed = BlockAnnotationPreview(
      BlockAnnotationSnapshot.fromJson(
        pending.result['block_annotations_before'] as Map,
      ),
      BlockAnnotationSnapshot.fromJson(
        pending.result['block_annotations'] as Map,
      ),
    );
    _issued[exposed] = pending;
    return exposed;
  }

  @override
  Future<BlockAnnotationPreview> previewAdd(
    BlockAnnotationSnapshot snapshot, {
    required int start,
    required int end,
    required BlockAnnotationKind kind,
    String? variant,
  }) => _preview({
    'kind': 'add',
    'start': start,
    'end': end,
    'block_kind': kind.name,
    'variant': ?variant,
    'content_id': snapshot.contentId,
  });
  @override
  Future<BlockAnnotationPreview> previewUpdate(
    BlockAnnotationSnapshot snapshot,
    String id, {
    required int start,
    required int end,
    required BlockAnnotationKind kind,
    String? variant,
    Map<int, String>? roles,
  }) => _preview({
    'kind': 'update',
    'id': id,
    'start': start,
    'end': end,
    'block_kind': kind.name,
    'variant': ?variant,
    if (roles != null && roles.isNotEmpty)
      'roles': {for (final e in roles.entries) '${e.key}': e.value},
    'content_id': snapshot.contentId,
  });
  @override
  Future<BlockAnnotationPreview> previewDelete(String id) =>
      _preview({'kind': 'delete', 'id': id});
  @override
  Future<BlockAnnotationPreview> previewUndo() => _preview({'kind': 'undo'});
  @override
  Future<BlockAnnotationPreview> previewRedo() => _preview({'kind': 'redo'});
  @override
  Future<void> confirm(BlockAnnotationPreview preview) async {
    _ready();
    final pending = _issued[preview];
    if (pending == null || !await backend.production.confirm(pending)) {
      throw const BlockAnnotationException('block_annotation_stale');
    }
    _issued[preview] = null;
  }

  @override
  void dispose() => _disposed = true;
}
