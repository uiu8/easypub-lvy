import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/inline_style_service.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class LegacyInlineStyleSession implements InlineStyleSession {
  LegacyInlineStyleSession(this.backend, this.bookId);
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
      throw const InlineStyleException('inline_style_stale');
    }
  }

  Future<ProductionPreview> _invoke(Map<String, Object?> action) async {
    _ready();
    final guard = backend.production.guardFor(bookId);
    final context = backend.illustrationContext(bookId);
    final publication = backend.publicationRequest(bookId);
    final current = publication['settings'];
    final request = jsonEncode({
      'op': 'inline_styles',
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
        throw const InlineStyleException('inline_style_stale');
      }
      return ProductionPreview(request, result, {bookId: guard})
        ..compositionGuards[bookId] = context;
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      throw InlineStyleException(detail['next_action'] as String);
    }
  }

  @override
  Future<InlineStyleSnapshot> list() async => InlineStyleSnapshot.fromJson(
    (await _invoke({'kind': 'list'})).result['inline_styles'] as Map,
  );

  @override
  Future<InlineStyleAnchor> resolvePosition(
    InlineStyleSnapshot snapshot, {
    required String entryId,
    required int line,
    required int utf16Start,
    required int utf16End,
  }) async {
    final result = await _invoke({
      'kind': 'resolve',
      'entry_id': entryId,
      'line': line,
      'utf16_start': utf16Start,
      'utf16_end': utf16End,
      'content_id': snapshot.contentId,
    });
    return InlineStyleAnchor.fromJson(result.result['selection'] as Map);
  }

  Future<InlineStylePreview> _preview(Map<String, Object?> action) async {
    final pending = await _invoke(action);
    final exposed = InlineStylePreview(
      InlineStyleSnapshot.fromJson(
        pending.result['inline_styles_before'] as Map,
      ),
      InlineStyleSnapshot.fromJson(pending.result['inline_styles'] as Map),
    );
    _issued[exposed] = pending;
    return exposed;
  }

  @override
  Future<InlineStylePreview> previewAdd(
    InlineStyleSnapshot snapshot,
    InlineStyleDraft draft,
  ) => _preview({
    'kind': 'add',
    'input': draft.toJson(),
    'content_id': snapshot.contentId,
  });
  @override
  Future<InlineStylePreview> previewAddAll(
    InlineStyleSnapshot snapshot,
    List<InlineStyleDraft> drafts,
  ) => _preview({
    'kind': 'add_many',
    'inputs': [for (final d in drafts) d.toJson()],
    'content_id': snapshot.contentId,
  });
  @override
  Future<InlineStylePreview> previewUpdate(
    InlineStyleSnapshot snapshot,
    String id,
    InlineStyleDraft draft,
  ) => _preview({
    'kind': 'update',
    'id': id,
    'input': draft.toJson(),
    'content_id': snapshot.contentId,
  });
  @override
  Future<InlineStylePreview> previewDelete(String id) =>
      _preview({'kind': 'delete', 'id': id});
  @override
  Future<InlineStylePreview> previewUndo() => _preview({'kind': 'undo'});
  @override
  Future<InlineStylePreview> previewRedo() => _preview({'kind': 'redo'});
  @override
  Future<void> confirm(InlineStylePreview preview) async {
    _ready();
    final pending = _issued[preview];
    if (pending == null || !await backend.production.confirm(pending)) {
      throw const InlineStyleException('inline_style_stale');
    }
    _issued[preview] = null;
  }

  @override
  void dispose() => _disposed = true;
}
