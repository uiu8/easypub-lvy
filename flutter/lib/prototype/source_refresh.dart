part of 'prototype_state.dart';

class _SourceRefreshCandidate extends SourceRefreshPreview {
  _SourceRefreshCandidate({
    required this.owner,
    required this.guard,
    required this.source,
    required this.fingerprint,
    required this.project,
    required super.bookId,
    required super.path,
    required super.bodyChanged,
    required super.oldLines,
    required super.newLines,
    required super.current,
    required super.incoming,
    required super.imagesChanged,
    required super.imageUpdateSummary,
    required this.images,
    required this.imageIdentity,
  });
  final PrototypeState owner;
  final String guard, fingerprint;
  final ImportedTxt source;
  final Map<String, dynamic> project;
  final List<Map<String, dynamic>> images;
  final String imageIdentity;
  bool consumed = false;
}

extension SourceRefreshOperations on PrototypeState {
  List<Map<String, dynamic>> _sourceImageRows(Map<String, dynamic>? report) =>
      (report?['image_placements'] as List? ?? [])
          .whereType<Map>()
          .where((v) => v['path'] is String && v['source_line'] is num)
          .map((v) => Map<String, dynamic>.from(v))
          .toList();

  Map<String, dynamic> _imageValue(Map v) => {
    'path': v['path'],
    'caption': v['caption'] ?? '',
    'alt': v['alt'] ?? '',
    if (v['source_line'] != null) 'source_line': v['source_line'],
  };

  List<String> _imageKeys(Map<String, dynamic>? report) {
    final hrefs = {
      for (final image in (report?['images'] as List? ?? []).whereType<Map>())
        image['path']: image['href'],
    };
    final occurrences = <String, int>{};
    return _sourceImageRows(report).map((row) {
      final base = jsonEncode([row['document'], hrefs[row['path']]]);
      final occurrence = occurrences.update(
        base,
        (n) => n + 1,
        ifAbsent: () => 0,
      );
      return '$base/$occurrence';
    }).toList();
  }

  Future<String> _imageIdentity(Map<String, dynamic>? report) async {
    final rows = _sourceImageRows(report), keys = _imageKeys(report);
    final hashes = <String, String>{};
    final values = <Object>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i], path = rows[i]['path'] as String;
      if (!hashes.containsKey(path)) {
        try {
          hashes[path] = await _sourceFingerprint(path);
        } on FileSystemException {
          hashes[path] = 'missing';
        }
      }
      values.add([
        keys[i],
        row['source_line'],
        row['caption'],
        row['alt'],
        hashes[path],
      ]);
    }
    return jsonEncode(values);
  }

  (List<Map<String, dynamic>>, int) _mergeSourceImages(
    Map<String, dynamic>? previous,
    Map<String, dynamic>? incoming,
    List<dynamic> current,
  ) {
    final oldRows = _sourceImageRows(previous),
        newRows = _sourceImageRows(incoming);
    final oldKeys = _imageKeys(previous), newKeys = _imageKeys(incoming);
    final oldByValue = <String, List<int>>{};
    for (var i = oldRows.length - 1; i >= 0; i--) {
      oldByValue
          .putIfAbsent(jsonEncode(_imageValue(oldRows[i])), () => [])
          .add(i);
    }
    final newByKey = {
      for (var i = 0; i < newRows.length; i++) newKeys[i]: newRows[i],
    };
    final oldKeySet = oldKeys.toSet();
    final next = <Map<String, dynamic>>[];
    var manual = 0;
    for (final image in current.cast<Map>()) {
      final matches = oldByValue[jsonEncode(_imageValue(image))];
      if (matches == null || matches.isEmpty) {
        next.add(Map<String, dynamic>.from(image));
        manual++;
        continue;
      }
      final index = matches.removeLast();
      final replacement = newByKey[oldKeys[index]];
      if (replacement != null) next.add(_imageValue(replacement));
    }
    for (var i = 0; i < newRows.length; i++) {
      // Do not silently resurrect an image the user removed or edited.
      if (!oldKeySet.contains(newKeys[i])) next.add(_imageValue(newRows[i]));
    }
    return (next, manual);
  }

  String _sourceRefreshGuard(String id) => jsonEncode([
    publicationContext(id),
    cleanup.histories[id],
    manuscript.findingReviews[id],
    shelf.books.firstWhere((b) => b.id == id).source?.path,
    production.drafts[id]?.epubResources,
    effectiveFolderRules,
  ]);

  void _requireRefreshIdle() {
    if (_disposed ||
        importing ||
        projectBusy ||
        production.busy ||
        cleanup.historyBusy ||
        queueActive) {
      throw const FormatException('请等待当前导入、检查或转换结束后刷新来源。');
    }
  }

  Future<String> _sourceFingerprint(String path) async {
    final file = File(path);
    final limit = path.toLowerCase().endsWith('.epub')
        ? 256 * 1024 * 1024
        : 128 * 1024 * 1024;
    if (await file.length() > limit) {
      throw const FormatException('来源文件超出导入大小限制。');
    }
    var total = 0;
    return (await sha256
            .bind(
              file.openRead().map((chunk) {
                total += chunk.length;
                if (_disposed || total > limit) {
                  throw const FormatException('来源读取已停止。');
                }
                return chunk;
              }),
            )
            .first)
        .toString();
  }

  Future<SourceRefreshPreview> previewSourceRefresh(String id) async {
    _requireRefreshIdle();
    final book = shelf.books.firstWhere((b) => b.id == id && !b.isDemo);
    final old = book.source!;
    final path = old.originPath ?? old.path;
    final guard = _sourceRefreshGuard(id);
    final doc =
        jsonDecode(jsonEncode(projectDocument())) as Map<String, dynamic>;
    // A recovery project contains this book and its full retained histories.
    doc['books'] = (doc['books'] as List)
        .where((b) => b['path'] == old.path)
        .toList();
    doc['current_path'] = old.path;
    final current =
        jsonDecode(jsonEncode(production.settings(id))) as Map<String, dynamic>;
    change(() => importing = true);
    try {
      final fingerprint = await _sourceFingerprint(path);
      final source = await _importer(path, () => _disposed);
      if (fingerprint != await _sourceFingerprint(path) ||
          guard != _sourceRefreshGuard(id)) {
        throw const FormatException('来源或书稿在读取期间改变，请重新读取。');
      }
      final metadata = (source.resourceReport?['metadata'] as Map?)
          ?.cast<String, dynamic>();
      final named = fileNameMetadata(
        path,
        FileNameOptions.fromConfiguration(globalConfiguration),
      );
      final incoming = <String, dynamic>{
        'title': (metadata?['title'] as String?)?.trim().isNotEmpty == true
            ? (metadata!['title'] as String).trim()
            : named.title,
        if (metadata != null) ...{
          for (final key in [
            'author',
            'description',
            ...bibliographicFields.keys,
          ])
            key: metadata[key] as String? ?? '',
          'cover_path': source.resourceReport?['cover_path'],
        },
        // 来源里没有作者时用文件名里的作者（V72）；刷新只是候选，由用户勾选是否采用。
        if ((metadata?['author'] as String?)?.trim().isNotEmpty != true &&
            named.author.isNotEmpty)
          'author': named.author,
      };
      final oldResources = production.drafts[id]?.epubResources;
      final imageIdentity = await _imageIdentity(source.resourceReport);
      final imagesChanged =
          old.sourceId == source.sourceId &&
          imageIdentity != await _imageIdentity(oldResources);
      final merged = _mergeSourceImages(
        oldResources,
        source.resourceReport,
        current['illustrations'] as List,
      );
      if (guard != _sourceRefreshGuard(id)) {
        throw const FormatException('书稿已改变，请重新读取来源。');
      }
      return _SourceRefreshCandidate(
        owner: this,
        guard: guard,
        fingerprint: fingerprint,
        source: source,
        project: doc,
        bookId: id,
        path: path,
        bodyChanged:
            old.sourceId != source.sourceId || old.revision != source.revision,
        oldLines: old.lines,
        newLines: source.lines,
        current: current,
        incoming: incoming,
        images: merged.$1,
        imageIdentity: imageIdentity,
        imagesChanged: imagesChanged,
        imageUpdateSummary:
            '来源插图 ${_sourceImageRows(oldResources).length} → ${_sourceImageRows(source.resourceReport).length} 处；保留 ${merged.$2} 处手工设置。',
      );
    } finally {
      change(() => importing = false);
    }
  }

  Future<SourceRefreshResult> applySourceRefresh(
    SourceRefreshPreview preview, {
    required Set<String> fields,
    required bool replaceBody,
    bool replaceImages = false,
  }) async {
    _requireRefreshIdle();
    if (preview is! _SourceRefreshCandidate ||
        !identical(preview.owner, this)) {
      throw const FormatException('刷新候选不属于当前工作区，请重新读取。');
    }
    final p = preview;
    void fresh() {
      if (_disposed ||
          p.consumed ||
          _sourceRefreshGuard(p.bookId) != p.guard ||
          queueActive) {
        throw const FormatException('书稿或任务已改变，请重新读取来源。');
      }
    }

    fresh();
    if (fields.any((key) => !p.incoming.containsKey(key))) {
      throw const FormatException('所选字段不在来源候选中。');
    }
    final replace = replaceBody && p.bodyChanged;
    final updateImages = replaceImages && p.imagesChanged && !p.bodyChanged;
    if (replaceImages && !updateImages) {
      throw const FormatException('当前候选不支持独立插图更新，请重新读取。');
    }
    if (fields.isEmpty && !replace && !p.bodyChanged && !updateImages) {
      return const SourceRefreshResult('没有采用任何更新，现有草稿保持不变。');
    }
    change(() => projectBusy = true);
    try {
      if (p.fingerprint != await _sourceFingerprint(p.path)) {
        throw const FormatException('来源文件又有变化，请重新读取后采用。');
      }
      fresh();
      if (updateImages &&
          p.imageIdentity != await _imageIdentity(p.source.resourceReport)) {
        throw const FormatException('候选插图已改变，请重新读取来源。');
      }
      fresh();
      final id = p.bookId;
      final old = shelf.books.firstWhere((b) => b.id == id);
      final source = replace ? p.source : old.source!;
      final values = jsonDecode(
        jsonEncode(production.settings(id)),
      ) as Map<String, dynamic>;
      if (replace) {
        final incomingImages =
            (p.source.resourceReport?['image_placements'] as List? ?? [])
                .whereType<Map>()
                .where((v) => v['path'] is String && v['source_line'] is num)
                .map(
                  (v) => <String, dynamic>{
                    'path': v['path'],
                    'caption': v['caption'] ?? '',
                    'alt': v['alt'] ?? '',
                    'source_line': (v['source_line'] as num).toInt(),
                  },
                )
                .toList();
        // Old manual images remain available, but their old line anchors do not.
        final paths = incomingImages.map((v) => v['path']).toSet();
        values['illustrations'] = [
          ...incomingImages,
          for (final v in (values['illustrations'] as List).cast<Map>())
            if (!paths.contains(v['path'])) {...v}..remove('source_line'),
        ];
      }
      final request = jsonEncode({
        'targets': [
          {
            'book_id': id,
            'current': values,
            'history': !replace && production.histories[id] != null
                ? production.histories[id]
                : {
                    'source_id': source.sourceId,
                    'revision': source.revision,
                    'states': [values],
                    'cursor': 0,
                  },
            'change': fields.isEmpty && !updateImages
                ? {'op': 'inspect'}
                : {
                    'op': 'source_metadata',
                    'fields': {for (final key in fields) key: p.incoming[key]},
                    if (updateImages) 'illustrations': p.images,
                  },
          },
        ],
      });
      final proposed = await production.productionRequest(request);
      fresh();
      final confirmed = await production.productionRequest(
        request,
        apply: true,
        planId: proposed['plan_id'] as String,
        confirmed: true,
      );
      fresh();
      final item = (confirmed['items'] as List).single as Map;
      final after = Map<String, dynamic>.from(item['after'] as Map);
      final history = Map<String, dynamic>.from(item['history'] as Map);
      final candidate =
          jsonDecode(jsonEncode(p.project)) as Map<String, dynamic>;
      final row = (candidate['books'] as List).single as Map<String, dynamic>;
      row.addAll(after);
      row['production_history'] = history;
      row['path'] = source.path;
      row['origin_path'] = p.path;
      row['source_id'] = source.sourceId;
      row['revision'] = source.revision;
      if (replace) {
        for (final key in [
          'cleanup',
          'cleanup_history',
          'structure',
          'structure_history',
          'effective_history',
          'manual_draft',
          'review',
          'reference_catalog',
        ]) {
          row.remove(key);
        }
        row['epub_resources'] = p.source.resourceReport;
      }
      if (updateImages) row['epub_resources'] = p.source.resourceReport;
      candidate['current_path'] = source.path;
      final root = Directory(
        StorageLocations.directory(
          'source_recovery',
          settingsDirectory: settingsDirectory,
        ),
      );
      await root.create(recursive: true);
      final folder = await root.createTemp('refresh-');
      final recovery = '${folder.path}/before.easypub.json';
      final staged = '${folder.path}/after.easypub.json';
      // Both projects are validated and durably published before active state changes.
      await projects.saveRecoveryProject(recovery, p.project);
      fresh();
      await projects.saveRecoveryProject(staged, candidate);
      fresh();
      if (p.fingerprint != await _sourceFingerprint(p.path)) {
        throw const FormatException('来源文件在保存期间变化，当前书稿未替换，请重新读取。');
      }
      fresh();
      final saved = jsonDecode(await File(staged).readAsString()) as Map;
      final savedRow = (saved['books'] as List).single as Map;
      final archivedPath = source_paths.join(
        folder.path,
        savedRow['path'] as String,
      );
      final restoredSource = ImportedTxt(
        path: archivedPath,
        originPath: p.path,
        sourceId: source.sourceId,
        revision: source.revision,
        encoding: source.encoding,
        lines: source.lines,
        headings: source.headings,
        resourceReport: replace || updateImages
            ? p.source.resourceReport
            : old.source!.resourceReport,
      );
      final book = SampleBook(
        id,
        after['title'] as String,
        after['author'] as String,
        restoredSource.headings,
        '已识别 · 尚未检查',
        source: restoredSource,
        format: old.format,
        hasCover: (after['cover_path'] as String?)?.isNotEmpty == true,
      );
      final draft = production.draftFromProduction(
        book,
        after,
        replace || updateImages
            ? p.source.resourceReport
            : production.drafts[id]?.epubResources,
      );
      fresh();
      final index = shelf.books.indexWhere((b) => b.id == id);
      change(() {
        p.consumed = true;
        shelf.books[index] = book;
        production.drafts[id] = draft;
        metadata[id] = (draft.title, draft.author);
        production.histories[id] = history;
        bookMembership[id] = (bookMembership[id] ?? 0) + 1;
        if (replace) {
          cleanup.drafts.remove(id);
          cleanup.histories.remove(id);
          cleanup.historyStatus.remove(id);
          manuscript.structures.remove(id);
          manuscript.structureHistories.remove(id);
          manuscript.effectiveHistories.remove(id);
          manuscript.manualEditDrafts.remove(id);
          manuscript.findingReviews.remove(id);
          _bookCatalogs.remove(id);
          _catalogSources.remove(id);
        }
        production.resourceIssues.remove(id);
        production.publicationReports.remove(id);
        production.coverInputs.remove(id);
      });
      return SourceRefreshResult(
        replace
            ? '已采用新正文；旧编辑保存在恢复项目中。'
            : updateImages
            ? '已更新来源插图，正文与章节编辑保留。'
            : '已采用所选信息，原正文与编辑历史保留。',
        recoveryPath: recovery,
      );
    } finally {
      change(() => projectBusy = false);
    }
  }
}
