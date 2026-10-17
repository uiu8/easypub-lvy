import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/supplemental_page_service.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

Future<T> _describe<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on api.ApiError catch (error) {
    final detail = jsonDecode(await api.describeApiError(error: error)) as Map;
    throw SupplementalPageException(detail['next_action'] as String);
  }
}

class LegacySupplementalPageSession implements SupplementalPageSession {
  LegacySupplementalPageSession(this.backend, this.bookId);
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
      throw const SupplementalPageException('supplemental_page_stale');
    }
  }

  Future<ProductionPreview> _invoke(Map<String, Object?> action) =>
      _describe(() async {
        _ready();
        final guard = backend.production.guardFor(bookId);
        final publication = backend.publicationRequest(bookId);
        final current = publication['settings'];
        final request = jsonEncode({
          'op': 'supplemental_pages',
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
        final result = await backend.production.productionRequest(request);
        _ready();
        if (guard != backend.production.guardFor(bookId)) {
          throw const SupplementalPageException('supplemental_page_stale');
        }
        return ProductionPreview(request, result, {bookId: guard});
      });
  @override
  Future<SupplementalPageSnapshot> list() async =>
      SupplementalPageSnapshot.fromJson(
        (await _invoke({'kind': 'list'})).result['supplemental_pages'] as List,
      );
  Future<SupplementalPagePreview> _preview(Map<String, Object?> action) async {
    final pending = await _invoke(action);
    final result = pending.result;
    final exposed = SupplementalPagePreview(
      SupplementalPageSnapshot.fromJson(
        result['supplemental_pages_before'] as List,
      ),
      SupplementalPageSnapshot.fromJson(result['supplemental_pages'] as List),
      List.unmodifiable(
        (result['warnings'] as List).cast<Map>().map(
          SupplementalPageWarning.fromJson,
        ),
      ),
    );
    _issued[exposed] = pending;
    return exposed;
  }

  @override
  Future<SupplementalPagePreview> previewAdd(SupplementalPageContent content) =>
      _preview({'kind': 'add', 'content': content.toJson()});
  @override
  Future<SupplementalPagePreview> previewUpdate(
    String id,
    SupplementalPageContent content,
  ) => _preview({'kind': 'update', 'id': id, 'content': content.toJson()});
  @override
  Future<SupplementalPagePreview> previewDelete(String id) =>
      _preview({'kind': 'delete', 'id': id});
  @override
  Future<SupplementalPagePreview> previewReorder(List<String> ids) =>
      _preview({'kind': 'reorder', 'ids': ids});
  @override
  Future<SupplementalPagePreview> previewMove(
    String id,
    SupplementalPagePosition position,
    List<String> ids,
  ) => _preview({
    'kind': 'move',
    'id': id,
    'position': position.name,
    'ids': ids,
  });
  @override
  Future<SupplementalPagePreview> previewApplyTemplate(
    SupplementalTemplate template,
  ) => _preview({
    'kind': 'apply_template',
    'template': template.toJson(),
    'year': DateTime.now().year,
  });
  @override
  Future<SupplementalPagePreview> previewUndo() => _preview({'kind': 'undo'});
  @override
  Future<SupplementalPagePreview> previewRedo() => _preview({'kind': 'redo'});
  @override
  Future<void> confirm(SupplementalPagePreview preview) => _describe(() async {
    _ready();
    final pending = _issued[preview];
    if (pending == null || !await backend.production.confirm(pending)) {
      throw const SupplementalPageException('supplemental_page_stale');
    }
    _issued[preview] = null;
  });
  @override
  void dispose() => _disposed = true;
}

class LegacySupplementalTemplateService implements SupplementalTemplateService {
  LegacySupplementalTemplateService(this.backend);
  final PrototypeState backend;
  SupplementalTemplateSnapshot _snapshot() => SupplementalTemplateSnapshot(
    backend.globalSettingsToken,
    backend.globalConfiguration['supplemental_templates'] as List? ?? [],
  );
  @override
  Future<SupplementalTemplateSnapshot> list() async {
    if (!await backend.loadGlobalSettings()) {
      throw const SupplementalPageException('supplemental_template_stale');
    }
    return _snapshot();
  }

  Future<SupplementalTemplateSnapshot> _edit(
    SupplementalTemplateSnapshot snapshot,
    Map<String, Object?> action,
  ) => _describe(() async {
    if (!backend.globalSettingsLoaded ||
        backend.globalSettingsBusy ||
        snapshot.token != backend.globalSettingsToken) {
      throw const SupplementalPageException('supplemental_template_stale');
    }
    final config = Map<String, dynamic>.from(backend.globalConfiguration);
    final result = await backend.production.productionRequest(
      jsonEncode({
        'op': 'supplemental_templates',
        'templates': config['supplemental_templates'] ?? [],
        'action': action,
      }),
    );
    config['supplemental_templates'] = result['templates'];
    if (utf8.encode(jsonEncode(config)).length > 4 * 1024 * 1024) {
      throw const SupplementalPageException('reduce_batch_history_size');
    }
    if (!await backend.saveGlobalConfiguration(config, snapshot.token)) {
      throw const SupplementalPageException(
        'supplemental_template_save_failed',
      );
    }
    return _snapshot();
  });
  @override
  Future<SupplementalTemplateSnapshot> save(
    SupplementalTemplateSnapshot snapshot, {
    String? id,
    required String name,
    required SupplementalPageContent content,
  }) => _edit(snapshot, {
    'kind': 'save',
    'id': id,
    'name': name,
    'content': content.toJson(),
  });
  @override
  Future<SupplementalTemplateSnapshot> delete(
    SupplementalTemplateSnapshot snapshot,
    String id,
  ) => _edit(snapshot, {'kind': 'delete', 'id': id});
}
