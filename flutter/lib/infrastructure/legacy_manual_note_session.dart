import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/manual_note_service.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class LegacyManualNoteSession implements ManualNoteSession {
  LegacyManualNoteSession(this.backend, this.bookId);
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
      throw const ManualNoteException('note_stale');
    }
  }

  Future<ProductionPreview> _invoke(Map<String, Object?> action) async {
    _ready();
    final guard = backend.production.guardFor(bookId);
    final context = backend.illustrationContext(bookId);
    final publication = backend.publicationRequest(bookId);
    final current = publication['settings'];
    final request = jsonEncode({
      'op': 'manual_notes',
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
        throw const ManualNoteException('note_stale');
      }
      return ProductionPreview(request, result, {bookId: guard})
        ..compositionGuards[bookId] = context;
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      throw ManualNoteException(detail['next_action'] as String);
    }
  }

  @override
  Future<ManualNoteSnapshot> list() async => ManualNoteSnapshot.fromJson(
    (await _invoke({'kind': 'list'})).result['manual_notes'] as Map,
  );

  @override
  Future<NoteSelection> resolvePosition(
    ManualNoteSnapshot snapshot, {
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
    return NoteSelection.fromJson(result.result['selection'] as Map);
  }

  Future<ManualNotePreview> _preview(Map<String, Object?> action) async {
    final pending = await _invoke(action);
    final exposed = ManualNotePreview(
      ManualNoteSnapshot.fromJson(pending.result['manual_notes_before'] as Map),
      ManualNoteSnapshot.fromJson(pending.result['manual_notes'] as Map),
    );
    _issued[exposed] = pending;
    return exposed;
  }

  @override
  Future<ManualNotePreview> previewAdd(
    ManualNoteSnapshot snapshot,
    ManualNoteDraft draft,
  ) => _preview({
    'kind': 'add',
    'input': draft.toJson(),
    'content_id': snapshot.contentId,
  });
  @override
  Future<ManualNotePreview> previewUpdate(
    ManualNoteSnapshot snapshot,
    String id,
    ManualNoteDraft draft,
  ) => _preview({
    'kind': 'update',
    'id': id,
    'input': draft.toJson(),
    'content_id': snapshot.contentId,
  });
  @override
  Future<ManualNotePreview> previewDelete(String id) =>
      _preview({'kind': 'delete', 'id': id});
  @override
  Future<ManualNotePreview> previewUndo() => _preview({'kind': 'undo'});
  @override
  Future<ManualNotePreview> previewRedo() => _preview({'kind': 'redo'});
  @override
  Future<void> confirm(ManualNotePreview preview) async {
    _ready();
    final pending = _issued[preview];
    if (pending == null || !await backend.production.confirm(pending)) {
      throw const ManualNoteException('note_stale');
    }
    _issued[preview] = null;
  }

  @override
  void dispose() => _disposed = true;
}
