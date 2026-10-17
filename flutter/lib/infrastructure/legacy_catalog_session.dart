import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/catalog_service.dart';
import '../application/chapter_service.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;
import 'legacy_chapter_session.dart';
import 'native_catalog_requests.dart';

typedef CatalogRequest = Future<String> Function({
  required String request,
  required String cookie,
});

class LegacyCatalogSession
    implements CatalogSession, CatalogCredentialSession, BookSourceSession {
  LegacyCatalogSession(this.backend, this.bookId, {CatalogRequest? request}) {
    _nativeRequests = request == null ? NativeCatalogRequests() : null;
    _request = request ?? _nativeRequests!.request;
  }
  @override
  bool useSavedCredential = true;
  Future<bool> _credential(String op, [String value = '']) async {
    final response = jsonDecode(
      await _request(
        request: jsonEncode({'op': op, 'source': 'qidian'}),
        cookie: value,
      ),
    ) as Map;
    if (response['error'] != null || response['saved'] is! bool) {
      throw FormatException(
        backend.catalogReason(
          response['reason']?.toString() ?? 'credential_storage_unavailable',
        ),
      );
    }
    return response['saved'] as bool;
  }

  @override
  Future<bool> credentialSaved() => _credential('credential_status');
  @override
  Future<void> saveCredential(String value) async {
    await _credential('credential_save', value);
  }

  @override
  Future<void> clearCredential() async {
    await _credential('credential_clear');
  }

  late final NativeCatalogRequests? _nativeRequests;
  late final CatalogRequest _request;
  final PrototypeState backend;
  final String bookId;
  int generation = 0;
  _Snapshot? _pending;
  _Alignment? _latest;
  CatalogRepairDraft? _repair;
  CatalogAlignment? _repairAlignment;

  Future<Map<String, dynamic>> _bookSourceRequest(
    String mode, {
    String input = '',
    String sourceId = '',
    BookSourceSearchResult? book,
    bool useCache = true,
  }) async {
    final ticket = ++generation;
    final guard = backend.publicationContext(bookId);
    _pending = null;
    _latest = null;
    final raw = await decodeCatalogResponse(
      await _request(
        request: await encodeCatalogRequest({
          'op': 'acquire',
          'source': mode,
          'book_source_id': sourceId,
          'input': input,
          'title': book?.title ?? '',
          'author': book?.author ?? '',
          'use_cache': useCache,
          'use_saved_cookie': false,
        }),
        cookie: '',
      ),
    );
    if (ticket != generation || guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('书源请求已取消或书稿已变化，请重新操作。');
    }
    if (raw['error'] != null) {
      throw FormatException(
        backend.catalogReason(
          raw['reason']?.toString() ?? 'book_source_parse_failed',
        ),
      );
    }
    return raw;
  }

  List<BookSourceInfo> _decodeBookSources(Map<String, dynamic> raw) {
    if (raw['stage'] != 'book_sources' || raw['sources'] is! List) {
      throw const FormatException('书源列表读取失败，请重新导入。');
    }
    return List.unmodifiable(
      (raw['sources'] as List).cast<Map>().map((row) {
        final reason = row['reason']?.toString() ?? '';
        return BookSourceInfo(
          id: row['id'].toString(),
          name: row['name'].toString(),
          url: row['url'].toString(),
          group: row['group']?.toString() ?? '',
          supported: row['supported'] == true,
          reasonCode: reason,
          reason: reason.isEmpty ? '' : backend.catalogReason(reason),
        );
      }),
    );
  }

  @override
  Future<List<BookSourceInfo>> listBookSources() async =>
      _decodeBookSources(await _bookSourceRequest('book_source_list'));

  @override
  Future<List<BookSourceInfo>> importBookSources(String path) async =>
      _decodeBookSources(
        await _bookSourceRequest('book_source_import', input: path),
      );

  @override
  Future<void> clearBookSources() async {
    _decodeBookSources(await _bookSourceRequest('book_source_clear'));
  }

  @override
  Future<List<BookSourceSearchResult>> searchBookSource(
    String sourceId,
    String query,
  ) async {
    final raw = await _bookSourceRequest(
      'book_source_search',
      sourceId: sourceId,
      input: query.trim(),
    );
    if (raw['stage'] != 'search_results' || raw['books'] is! List) {
      throw const FormatException('书源搜索未返回有效结果。');
    }
    return List.unmodifiable(
      (raw['books'] as List).cast<Map>().map(
        (row) => BookSourceSearchResult(
          row['book_id'].toString(),
          row['title'].toString(),
          row['url'].toString(),
          sourceId: sourceId,
          author: row['author']?.toString() ?? '',
          lastChapter: row['last_chapter']?.toString() ?? '',
        ),
      ),
    );
  }

  @override
  Future<CatalogSnapshot> acquireBookSource(
    BookSourceSearchResult book, {
    bool useCache = true,
  }) async {
    final guard = backend.publicationContext(bookId);
    final raw = await _bookSourceRequest(
      'book_source_toc',
      sourceId: book.sourceId,
      input: book.url,
      book: book,
      useCache: useCache,
    );
    if (raw['catalog'] is! Map) throw const FormatException('书源未返回有效目录。');
    return _pending = _decode(
      (raw['catalog'] as Map).cast<String, dynamic>(),
      guard,
      raw['duplicate_segments'] as List? ?? const [],
      raw['from_cache'] == true,
      raw['cache_stale'] == true,
    );
  }

  @override
  CatalogSnapshot? get saved {
    final value = backend.savedReferenceCatalog(bookId);
    return value == null ? null : _decode(value, '');
  }

  _Snapshot _decode(
    Map<String, dynamic> raw,
    String guard, [
    List<dynamic> duplicates = const [],
    bool fromCache = false,
    bool cacheStale = false,
  ]) => _Snapshot(
    raw['title']?.toString() ?? '',
    raw['author']?.toString() ?? '',
    raw['origin']?.toString() ?? '',
    raw['completeness']?.toString() ?? 'unknown',
    List.unmodifiable(
      (raw['entries'] as List).cast<Map>().map(
        (e) => CatalogEntry(
          e['title'].toString(),
          e['volume']?.toString() ?? '',
          e['volume_kind'] == 'structural',
        ),
      ),
    ),
    raw,
    guard,
    fromCache: fromCache,
    cacheStale: cacheStale,
    duplicateSegments: duplicates
        .map(
          (d) => CatalogDuplicateSegment(
            d['original_start'] as int,
            d['start'] as int,
            d['length'] as int,
            d['first_title'] as String,
            d['last_title'] as String,
          ),
        )
        .toList(growable: false),
  );

  @override
  Future<List<CatalogSearchResult>> search(
    String query, {
    String cookie = '',
  }) async {
    final value = query.trim();
    if (value.isEmpty || utf8.encode(value).length > 512) {
      throw const FormatException('请输入书名，搜索文字不能超过512字节。');
    }
    final ticket = ++generation;
    final guard = backend.publicationContext(bookId);
    _pending = null;
    _latest = null;
    final response = jsonDecode(
      await _request(
        request: jsonEncode({
          'op': 'acquire',
          'source': 'search',
          'use_saved_cookie': useSavedCredential,
          'input': value,
        }),
        cookie: cookie,
      ),
    ) as Map<String, dynamic>;
    if (ticket != generation || guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('搜索已取消或书稿已变化，请重新搜索。');
    }
    if (response['stage'] != 'search_results' || response['books'] is! List) {
      throw FormatException(
        backend.catalogReason(response['reason']?.toString() ?? '搜索未返回有效结果'),
      );
    }
    return List.unmodifiable(
      (response['books'] as List).map(
        (row) => CatalogSearchResult(
          row['book_id'].toString(),
          row['title'].toString(),
          row['url'].toString(),
        ),
      ),
    );
  }

  @override
  Future<CatalogSnapshot> acquire(
    String source,
    String input, {
    String cookie = '',
    int? declaredTotal,
    bool useCache = true,
  }) async {
    if (!['qidian', 'local', 'paste'].contains(source) ||
        input.trim().isEmpty) {
      throw const FormatException('请提供有效的目录来源。');
    }
    if (declaredTotal != null &&
        (source == 'qidian' || declaredTotal < 1 || declaredTotal > 30000)) {
      throw const FormatException('本地目录声明章节数必须为 1–30000；在线目录使用网站提供的范围。');
    }
    final ticket = ++generation;
    _pending = null;
    _latest = null;
    final guard = backend.publicationContext(bookId);
    final book = backend.shelf.books.firstWhere((b) => b.id == bookId);
    final raw = await decodeCatalogResponse(
      await _request(
        request: await encodeCatalogRequest({
          'op': 'acquire',
          'source': source,
          'use_saved_cookie': source == 'qidian' && useSavedCredential,
          'input': input.trim(),
          'title': book.title,
          'author': book.author,
          'use_cache': useCache,
          'total': ?declaredTotal,
        }),
        cookie: source == 'qidian' ? cookie : '',
      ),
    );
    if (ticket != generation || guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('目录请求已取消或书稿已变化，请重新获取。');
    }
    if (raw['error'] != null || raw['catalog'] is! Map) {
      throw FormatException(
        backend.catalogReason(raw['reason']?.toString() ?? '目录获取失败'),
      );
    }
    return _pending = _decode(
      (raw['catalog'] as Map).cast<String, dynamic>(),
      guard,
      raw['duplicate_segments'] as List? ?? const [],
      raw['from_cache'] == true,
      raw['cache_stale'] == true,
    );
  }

  @override
  Future<CatalogSnapshot> removeDuplicateSegments(
    CatalogSnapshot candidate,
    Set<int> starts,
  ) async {
    if (candidate is! _Snapshot ||
        !identical(candidate, _pending) ||
        candidate.guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('目录候选已变化，请重新获取。');
    }
    final ticket = ++generation;
    final raw = await decodeCatalogResponse(
      await _request(
        request: await encodeCatalogRequest({
          'op': 'remove_duplicate_segments',
          'catalog_id': candidate.raw['id'],
          'catalog_snapshot': candidate.raw,
          'starts': starts.toList(),
          'confirmed': true,
        }),
        cookie: '',
      ),
    );
    if (ticket != generation ||
        candidate.guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('目录请求已取消或书稿已变化。');
    }
    if (raw['catalog'] is! Map) {
      throw const FormatException('重复片段确认已过期，请重新获取目录。');
    }
    _latest = null;
    return _pending = _decode(
      (raw['catalog'] as Map).cast<String, dynamic>(),
      candidate.guard,
      raw['duplicate_segments'] as List? ?? const [],
    );
  }

  @override
  void accept(CatalogSnapshot candidate) {
    if (candidate is! _Snapshot ||
        !identical(candidate, _pending) ||
        candidate.guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('目录候选已变化，请重新获取并核对身份。');
    }
    backend.saveReferenceCatalog(bookId, candidate.raw);
    _pending = null;
  }

  @override
  void cancel() {
    _nativeRequests?.cancel();
    generation++;
    _pending = null;
    _latest = null;
    _repair = null;
    _repairAlignment = null;
  }

  @override
  Future<CatalogAlignment> preview(
    CatalogSnapshot snapshot, {
    required bool identityConfirmed,
    bool reorder = false,
  }) => _preview(
    snapshot,
    identityConfirmed: identityConfirmed,
    reorder: reorder,
  );

  Future<CatalogAlignment> _preview(
    CatalogSnapshot snapshot, {
    required bool identityConfirmed,
    bool reorder = false,
    Map<String, String> choices = const {},
    Map<int, List<CatalogChoice>> domains = const {},
  }) async {
    if (!identityConfirmed || snapshot is! _Snapshot) {
      throw const FormatException('请先核对并确认目录身份。');
    }
    final ticket = ++generation;
    final guard = backend.publicationContext(bookId);
    final stored = backend.savedReferenceCatalog(bookId);
    if (!identical(snapshot, _pending) &&
        !await compute(_sameCatalog, (stored, snapshot.raw))) {
      throw const ChapterStateChanged('目录快照已变化，请重新获取。');
    }
    final source = backend.shelf.books.firstWhere((b) => b.id == bookId).source;
    if (source == null) throw const FormatException('请先导入真实书稿。');
    final response = await decodeCatalogResponse(
      await _request(
        request: await encodeCatalogRequest({
          'op': 'preview_effective',
          'base': backend.manuscript.effectiveBase(bookId),
          'post_edits': backend.manuscript.effectiveSelection(bookId),
          'catalog_id': snapshot.raw['id'],
          'catalog_snapshot': snapshot.raw,
          'source_id': source.sourceId,
          'revision': source.revision,
          'identity_confirmed': true,
          'choices': choices,
          'reorder': reorder,
        }),
        cookie: '',
      ),
    );
    if (ticket != generation || guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('书稿状态已变化，请重新生成目录对齐。');
    }
    if (response['error'] != null || response['plan'] is! Map) {
      throw FormatException(
        backend.catalogReason(response['reason']?.toString() ?? '目录对齐失败'),
      );
    }
    final plan = response['plan'] as Map;
    final available = Map<int, List<CatalogChoice>>.of(domains);
    final entries = {
      for (final e in (snapshot.raw['entries'] as List).cast<Map>()) e['id']: e,
    };
    for (final m in (plan['unresolved'] as List).cast<Map>()) {
      if (m['reason'] == 'ambiguous_cross_volume' && m['line'] is int) {
        available[m['line'] as int] = List.unmodifiable([
          for (final id in m['candidate_ids'] as List)
            CatalogChoice(
              id as String,
              entries[id]!['title'].toString(),
              entries[id]!['volume'].toString(),
            ),
        ]);
      }
    }
    final rows = <CatalogAlignmentRow>[
      for (final m in (plan['matches'] as List).cast<Map>())
        CatalogAlignmentRow(
          m['title']?.toString() ?? '',
          m['catalog_title']?.toString() ?? '',
          m['line'] as int?,
          m['order_conflict'] == true
              ? reorder && plan['relocation'] != null
                    ? '将按目录归位'
                    : '顺序冲突，需核对'
              : switch (m['status']) {
                  'missing_heading' => '已找到标题，尚未收入目录',
                  'title_difference' => '已对应，标题不同',
                  _ => '已对应',
                },
          candidates: available[m['line']] ?? const [],
          chosenId: choices['${m['line']}'],
        ),
      for (final m in (plan['unresolved'] as List).cast<Map>())
        CatalogAlignmentRow(
          m['catalog_entry_id'] == null ? m['title']?.toString() ?? '' : '',
          m['catalog_entry_id'] != null ? m['title']?.toString() ?? '' : '',
          m['line'] as int?,
          switch (m['reason']) {
            'duplicate_catalog_segments_require_review' =>
              '参考目录存在重复片段，请返回目录来源集中核对',
            'unmatched' => '未匹配到参考标题',
            'ambiguous_cross_volume' => '跨卷同名，需选择对应',
            'duplicate_local_chapter_body_not_removed' => '本地重复标题，正文未删除',
            'not_located_no_body_created' => '参考章节未定位，不补写正文',
            'catalog_scope_not_verified_complete' => '目录完整性未确认',
            'order_conflict_review_required' => '顺序冲突，需核对',
            'chapter_volume_differs_enable_reorder' => '章节所在卷与目录不同，可启用按目录整章归位',
            'existing_volume_or_intro_requires_review' => '已有卷或卷前文字，需核对',
            'volume_boundary_not_proven' => '卷边界尚未证实',
            _ => backend.catalogReason(m['reason']?.toString() ?? '需人工核对'),
          },
          candidates: available[m['line']] ?? const [],
          chosenId: choices['${m['line']}'],
        ),
    ];
    final commands = <String, List<dynamic>>{};
    final dependencies = <String, List<String>>{};
    final changes = <ChapterRepairChange>[];
    for (final v in (plan['changes'] as List? ?? const []).cast<Map>()) {
      final id = v['finding_id'] as String;
      commands[id] = v['actions'] as List;
      dependencies[id] = (v['requires'] as List? ?? const []).cast<String>();
      changes.add(
        ChapterRepairChange(
          id,
          v['entry_id'] as String,
          v['title'] as String,
          v['line'] as int,
          v['kept_line'] as int,
          v['before'] as String,
          v['after'] as String,
          v['truncated'] == true,
          recommended: v['recommended'] == true,
          requires: List<String>.from(v['requires'] ?? []),
        ),
      );
    }
    final relocated = plan['relocated_chapters'] as int? ?? 0;
    return _latest = _Alignment(
      List.unmodifiable(rows),
      plan['matched'] as int,
      (plan['unresolved'] as List).length,
      changes.length,
      snapshot,
      guard,
      Map.unmodifiable(choices),
      Map.unmodifiable(available),
      plan['plan_id'] as String,
      commands,
      dependencies,
      changes: changes,
      reorder: reorder,
      relocatedChapters: relocated,
    );
  }

  @override
  Future<CatalogAlignment> choose(
    CatalogAlignment previous,
    int line,
    String? entryId,
  ) async {
    if (previous is! _Alignment ||
        !identical(previous, _latest) ||
        previous.guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('对齐结果已过期，请重新生成预览。');
    }
    final options = previous.domains[line];
    if (options == null ||
        (entryId != null && !options.any((e) => e.id == entryId))) {
      throw const FormatException('请选择该原稿行的目录候选。');
    }
    final choices = Map<String, String>.of(previous.choices);
    entryId == null ? choices.remove('$line') : choices['$line'] = entryId;
    return _preview(
      previous.snapshot,
      identityConfirmed: true,
      choices: choices,
      domains: previous.domains,
      reorder: previous.reorder,
    );
  }

  @override
  Future<String> evidence(
    CatalogAlignment alignment,
    CatalogAlignmentRow row,
  ) async {
    final ticket = generation;
    void validate() {
      if (alignment is! _Alignment ||
          !identical(alignment, _latest) ||
          ticket != generation ||
          alignment.guard != backend.publicationContext(bookId)) {
        throw const ChapterStateChanged('对齐结果已过期，请重新生成预览。');
      }
      if (!alignment.rows.contains(row) || row.line == null || row.line! < 1) {
        throw const FormatException('该对应项没有有效的原稿定位。');
      }
    }

    validate();
    final source = backend.shelf.books
        .firstWhere((b) => b.id == bookId)
        .source!;
    final base = backend.manuscript.effectiveBase(bookId);
    final raw = await api.effectiveStructureText(
      sourceId: source.sourceId,
      revision: source.revision,
      settingsJson: base['structure'] == null
          ? ''
          : jsonEncode(base['structure']),
      selectedJson: jsonEncode({
        'kind': 'publication',
        'manual': base['manual'],
        'cleanup': base['cleanup'],
        'post_edits': backend.manuscript.effectiveSelection(bookId),
        'effective_check': {'offset': 0, 'line': row.line},
      }),
      offset: 0,
    );
    final rows =
        ((jsonDecode(raw) as Map)['effective_check'] as Map)['excerpt'] as List;
    final text = rows
        .cast<Map>()
        .map((r) => "${r['line']}: ${r['text']}")
        .join('\n');
    validate();
    return text;
  }

  void _validateAlignment(CatalogAlignment alignment, int ticket) {
    if (alignment is! _Alignment ||
        !identical(alignment, _latest) ||
        ticket != generation ||
        alignment.guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('对齐或草稿已变化，请重新生成目录预览。');
    }
  }

  @override
  Future<CatalogRepairDraft> prepareRepair(
    CatalogAlignment alignment, {
    Set<String>? selectedIds,
  }) async {
    final ticket = generation;
    _validateAlignment(alignment, ticket);
    if (selectedIds == null &&
        identical(_repairAlignment, alignment) &&
        _repair != null) {
      return _repair!;
    }
    final plan = alignment as _Alignment;
    final session = _CatalogChapterSession(
      backend,
      bookId,
      () => _validateAlignment(alignment, ticket),
    );
    final before = await session.read(0);
    _validateAlignment(alignment, ticket);
    final ids =
        selectedIds ??
        alignment.changes.where((c) => c.recommended).map((c) => c.id).toSet();
    if (ids.isEmpty) {
      final preview = await session.previewCurrentCopy(before);
      _repairAlignment = alignment;
      return _repair = CatalogRepairDraft(session, before, preview);
    }
    if (ids.any((id) => !plan.commands.containsKey(id))) {
      throw const FormatException('请选择本次要处理的项目。');
    }
    for (final id in ids) {
      if (plan.dependencies[id]!.any(
        (dependency) => !ids.contains(dependency),
      )) {
        throw const FormatException('建立卷需要先把对应标题收入目录，请同时选择这两项。');
      }
    }
    final changes = alignment.changes.where((c) => ids.contains(c.id)).toList();
    int phase(ChapterRepairChange c) => c.id.startsWith('catalog-volume:')
        ? 2
        : c.id == 'catalog-reorder'
        ? 3
        : 0;
    changes.sort((a, b) {
      final p = phase(a).compareTo(phase(b));
      return p != 0
          ? p
          : phase(a) == 2
          ? a.line.compareTo(b.line)
          : b.line.compareTo(a.line);
    });
    final preview = await session.prepareActions(before, [
      for (final c in changes) ...plan.commands[c.id]!,
    ]);
    _validateAlignment(alignment, ticket);
    _repairAlignment = alignment;
    return _repair = CatalogRepairDraft(session, before, preview);
  }

  @override
  Future<ChapterPage> composition(
    CatalogAlignment alignment,
    int offset, {
    required bool withCatalog,
    String? nodeId,
    int bodyOffset = 0,
  }) async {
    final ticket = generation;
    _validateAlignment(alignment, ticket);
    if (offset < 0 || bodyOffset < 0) throw const FormatException('无效的预览位置。');
    ChapterPage page;
    ChapterBody? body;
    if (withCatalog && alignment.proposedEdits > 0) {
      final draft = await prepareRepair(alignment);
      page = await draft.session.previewTree(draft.preview, offset);
      nodeId ??=
          page.nodes.where((n) => n.role == 'chapter').firstOrNull?.id ??
          page.nodes.firstOrNull?.id;
      if (nodeId != null) {
        body = await draft.session.previewBody(
          draft.preview,
          nodeId,
          bodyOffset,
        );
      }
    } else {
      final session = LegacyChapterSession(backend, bookId);
      page = await session.read(offset);
      nodeId ??=
          page.nodes.where((n) => n.role == 'chapter').firstOrNull?.id ??
          page.nodes.firstOrNull?.id;
      if (nodeId != null) body = await session.body(page, nodeId, bodyOffset);
    }
    _validateAlignment(alignment, ticket);
    return ChapterPage(
      page.nodes,
      page.total,
      offset,
      page.guard,
      body: body,
      bodyNodeId: nodeId,
    );
  }
}

class _Alignment extends CatalogAlignment {
  const _Alignment(
    super.rows,
    super.matched,
    super.unresolved,
    super.proposedEdits,
    this.snapshot,
    this.guard,
    this.choices,
    this.domains,
    this.planId,
    this.commands,
    this.dependencies, {
    super.changes,
    super.reorder = false,
    super.relocatedChapters = 0,
  });
  final CatalogSnapshot snapshot;
  final String guard;
  final String planId;
  final Map<String, List<dynamic>> commands;
  final Map<String, List<String>> dependencies;
  final Map<String, String> choices;
  final Map<int, List<CatalogChoice>> domains;
}

class _Snapshot extends CatalogSnapshot {
  const _Snapshot(
    super.title,
    super.author,
    super.origin,
    super.completeness,
    super.entries,
    this.raw,
    this.guard, {
    super.duplicateSegments,
    super.fromCache,
    super.cacheStale,
  });
  final Map<String, dynamic> raw;
  final String guard;
}

/// Catalog choices are session-local, so the ordinary draft guard alone cannot
/// reject a cancelled or superseded catalog proposal.
class _CatalogChapterSession extends LegacyChapterSession {
  _CatalogChapterSession(super.backend, super.bookId, this.validateCatalog);
  final void Function() validateCatalog;
  @override
  Future<ChapterCopyReceipt> exportCopy(
    ChapterEditPreview preview,
    String outputPath,
  ) async {
    validateCatalog();
    return super.exportCopy(preview, outputPath);
  }

  @override
  Future<void> confirm(ChapterEditPreview preview) async {
    validateCatalog();
    await super.confirm(preview);
  }

  @override
  Future<ChapterPage> previewTree(
    ChapterEditPreview preview,
    int offset,
  ) async {
    validateCatalog();
    final page = await super.previewTree(preview, offset);
    validateCatalog();
    return page;
  }

  @override
  Future<ChapterBody> previewBody(
    ChapterEditPreview preview,
    String nodeId,
    int offset,
  ) async {
    validateCatalog();
    final body = await super.previewBody(preview, nodeId, offset);
    validateCatalog();
    return body;
  }
}

bool _sameCatalog((Map<String, dynamic>?, Map<String, dynamic>) catalogs) =>
    jsonEncode(catalogs.$1) == jsonEncode(catalogs.$2);
