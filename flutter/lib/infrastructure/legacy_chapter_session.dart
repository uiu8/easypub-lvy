import 'dart:convert';

import '../application/chapter_service.dart';
import '../src/rust/api.dart' as api;
import '../prototype/prototype_state.dart';

class LegacyChapterSession
    implements
        ChapterSession,
        FilteredChapterSession,
        ChapterIssueContextSession,
        ChapterCheckpointSession,
        ChapterOutlineSession,
        TargetedChapterRepairSession,
        ChapterRepairComparisonSession,
        ChapterBodyContinuationSession,
        ChapterCopySession,
        ChapterIssueMapSession,
        ChapterRepairImpactSession,
        BatchIssueReviewSession {
  LegacyChapterSession(this.backend, this.bookId);
  final PrototypeState backend;
  final String bookId;
  _Candidate? _pending;
  _Candidate? _lastConfirmed;
  String? _confirmedGuard;
  int _previewGeneration = 0;
  String? _compositionKey, _compositionGuard;

  Future<Map> _view(int offset, Map<String, dynamic> query) async {
    final guard = backend.publicationContext(bookId);
    final book = backend.shelf.books.firstWhere((b) => b.id == bookId);
    var key = _compositionGuard == guard ? _compositionKey : null;
    Future<String> request() {
      final base = key == null
          ? backend.manuscript.effectiveBase(bookId)
          : null;
      return api.effectiveStructureText(
        sourceId: book.source!.sourceId,
        revision: book.source!.revision,
        settingsJson: base?['structure'] == null
            ? ''
            : jsonEncode(base!['structure']),
        selectedJson: jsonEncode({
          'kind': 'publication',
          'composition_key': ?key,
          if (base != null) ...{
            'manual': base['manual'],
            'cleanup': base['cleanup'],
            'post_edits': backend.manuscript.effectiveSelection(bookId),
          },
          ...query,
        }),
        offset: offset,
      );
    }

    String raw;
    try {
      raw = await request();
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      if (key == null || detail['next_action'] != 'refresh_composition') {
        rethrow;
      }
      if (guard != backend.publicationContext(bookId)) {
        throw const ChapterStateChanged('书稿已变化，请刷新。');
      }
      key = null;
      raw = await request();
    }
    if (guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('书稿已变化，请刷新。');
    }
    final result = jsonDecode(raw) as Map;
    _compositionKey = result['composition_key'] as String?;
    _compositionGuard = guard;
    return result;
  }

  String get _reviewGuard =>
      jsonEncode(backend.manuscript.findingReviews[bookId] ?? {'records': {}});

  @override
  Future<ChapterIssuePage> issues(
    ChapterPage page,
    int offset, {
    bool effective = false,
  }) async {
    check(page);
    if (effective) {
      final result = await _effectiveCheck(page, offset);
      return _effectiveReport(page, offset, result);
    }

    return _review(page, offset);
  }

  @override
  Future<ChapterIssuePage> filteredIssues(
    ChapterPage page,
    int offset, {
    bool effective = false,
    String? category,
    String? severity,
  }) async {
    check(page);
    if (effective) {
      final result = await _effectiveCheck(
        page,
        offset,
        category: category,
        severity: severity,
      );
      return _effectiveReport(
        page,
        offset,
        result,
        category: category,
        severity: severity,
      );
    }
    return _review(page, offset, category: category, severity: severity);
  }

  ChapterIssuePage _effectiveReport(
    ChapterPage page,
    int offset,
    Map result, {
    String? category,
    String? severity,
  }) {
    final diagnostic = (result['report'] as Map)['diagnostic'] as Map;
    final items = (diagnostic['review_items'] as List)
        .cast<Map>()
        .map(_effectiveIssue)
        .toList();
    return _EffectiveIssues(
      List.unmodifiable(items),
      diagnostic['review_total'] as int,
      offset,
      this,
      page,
      result['composition_id'] as String,
      (result['report'] as Map)['evidence_id'] as String,
      _reviewGuard,
      categoryCounts: Map<String, int>.from(
        diagnostic['review_categories'] ?? {},
      ),
      severityCounts: Map<String, int>.from(
        diagnostic['review_severities'] ?? {},
      ),
      filteredCategoryCounts: Map<String, int>.from(
        diagnostic['review_filtered_categories'] ?? {},
      ),
      reviewed: diagnostic['review_reviewed'] as int?,
      unfilteredTotal: diagnostic['review_unfiltered_total'] as int?,
      categoryFilter: category,
      severityFilter: severity,
    );
  }

  static ChapterIssue _effectiveIssue(Map v) => ChapterIssue(
    v['id'] as String,
    v['finding_id'] as String,
    v['title'] as String,
    v['evidence'] as String? ?? '',
    List.unmodifiable((v['source_lines'] as List).cast<int>()),
    (v['review'] as Map?)?['decision'] as String?,
    v['category_reviewed'] == true,
    v['auto_applicable'] == true,
    severity: v['severity'] as String? ?? 'info',
    subtype: v['subtype'] as String?,
    originalLines: List<int?>.unmodifiable(
      (v['original_source_lines'] as List? ?? const []).cast<int?>(),
    ),
    entryId: v['entry_id'] as String?,
    nodeOffset: v['node_offset'] as int?,
    hasSuggestion: v['has_suggestion'] == true,
    anchors: [
      for (final a in (v['anchors'] as List? ?? const []).cast<Map>())
        ChapterIssueAnchor(
          a['title'] as String,
          a['line'] as int,
          a['entry_id'] as String,
          a['node_offset'] as int,
          a['body_offset'] as int,
          a['original_line'] as int?,
          startLine: a['start_line'] as int?,
          endLine: a['end_line'] as int?,
        ),
    ],
  );

  @override
  Future<ChapterIssueMap> issueMap(
    ChapterPage page, {
    bool summary = true,
    String? entryId,
  }) async {
    final result = await _effectiveCheck(
      page,
      0,
      contextOnly: true,
      positions: {'summary': summary, 'entry_id': entryId},
    );
    final positions = result['positions'] as Map;
    final chapter = positions['chapter'] as Map?;
    final items = ((chapter?['items'] as List?) ?? const []).cast<Map>();
    return ChapterIssueMap(
      guard: page.guard,
      evidenceId: positions['evidence_id'] as String,
      total: positions['total'] as int,
      open: positions['open'] as int,
      openSeverities: Map<String, int>.from(
        positions['open_severities'] as Map,
      ),
      marks: {
        for (final row
            in ((positions['nodes'] as List?) ?? const []).cast<Map>())
          row['entry_id'] as String: ChapterIssueMark(
            row['entry_id'] as String,
            row['severity'] as String,
            row['count'] as int,
            row['open'] as int,
            index: row['index'] as int?,
          ),
      },
      chapterId: chapter?['entry_id'] as String?,
      chapterIssues: List.unmodifiable(items.map(_effectiveIssue)),
      chapterTotal: chapter?['total'] as int? ?? 0,
      reviewIndex: {
        for (final v in items) v['id'] as String: v['review_index'] as int,
      },
    );
  }

  @override
  Future<ChapterRepairOptions> repairs(ChapterPage page) => _repairs(page);
  @override
  Future<ChapterRepairOptions> repairsForIssue(
    ChapterPage page,
    String issueId,
  ) => _repairs(page, focus: issueId);
  Future<ChapterRepairOptions> _repairs(
    ChapterPage page, {
    String? focus,
  }) async {
    final result = await _effectiveCheck(page, 0, repairFocus: focus);
    final raw = result['repairs'] as Map;
    final commands = <String, List<dynamic>>{};
    for (final v in (raw['items'] as List).cast<Map>()) {
      commands[v['finding_id'] as String] = v['actions'] as List;
    }
    final changes = (raw['items'] as List)
        .cast<Map>()
        .map(
          (v) => ChapterRepairChange(
            v['finding_id'] as String,
            v['entry_id'] as String,
            v['title'] as String,
            v['line'] as int,
            v['kept_line'] as int,
            v['before'] as String,
            v['after'] as String,
            v['truncated'] == true,
            recommended: v['recommended'] == true,
          ),
        )
        .toList();
    return _RepairOptions(
      List.unmodifiable(changes),
      raw['total'] as int,
      _effectiveReport(page, 0, result),
      this,
      page,
      commands,
    );
  }

  @override
  Future<ChapterRepairPlan> previewRepairs(
    ChapterRepairOptions options,
    Set<String> selectedIds,
  ) async {
    if (options is! _RepairOptions || !identical(options.owner, this)) {
      throw const FormatException('修复方案不属于当前会话，请重新检查。');
    }
    check(options.page);
    final selected = options.changes
        .where((c) => selectedIds.contains(c.id))
        .toList();
    if (selected.isEmpty || selected.length != selectedIds.length) {
      throw const FormatException('请选择当前方案内的安全修复项。');
    }
    selected.sort((a, b) => b.line.compareTo(a.line));
    final actions = [for (final c in selected) ...options.commands[c.id]!];
    final createsChapters = actions.every(
      (a) =>
          a['kind'] == 'create_boundary' &&
          a['role'] == 'chapter' &&
          a['include_toc'] == true,
    );
    final candidate = await _previewCommand(options.page, {
      'op': 'append_batch',
      'actions': createsChapters
          ? [
              {
                'kind': 'create_chapter_boundaries',
                'boundaries': [
                  for (final a in actions)
                    {
                      'entry_id': a['entry_id'],
                      'line_offset': a['line_offset'],
                      'depth': a['depth'],
                    },
                ],
              },
            ]
          : actions,
    });
    return ChapterRepairPlan(candidate, List.unmodifiable(selected));
  }

  Future<Map> _effectiveCheck(
    ChapterPage page,
    int offset, {
    int? line,
    int? originalLine,
    bool contextOnly = false,
    String? category,
    String? severity,
    String? repairFocus,
    Map<String, dynamic>? reviewChange,
    List<Map<String, dynamic>>? reviewChanges,
    Map<String, dynamic>? positions,
  }) async {
    check(page);
    final result = await _view(0, {
      if (contextOnly) 'response_scope': 'context',
      'effective_check': {
        'offset': offset,
        'line': line,
        'original_line': ?originalLine,
        'repair_focus': repairFocus,
        'review': _effectiveReviews(),
        'review_change': reviewChange,
        'review_changes': ?reviewChanges,
        'positions': ?positions,
        'category': category,
        'severity': severity,
      },
    });
    check(page);
    return result['effective_check'] as Map;
  }

  Map<String, dynamic> _effectiveReviews() => {
    'records': {
      for (final entry
          in ((backend.manuscript.findingReviews[bookId]?['records'] as Map?) ??
                  {})
              .entries)
        if (entry.key.toString().startsWith('effective:'))
          entry.key.toString().substring(10): entry.value,
    },
  };

  /// 对指定的后续编辑（null 为当前编辑稿）运行问题位置汇总，只读。
  Future<Map> _positionsSummary(
    Map<String, dynamic>? postEdits, {
    required bool current,
  }) async {
    final book = backend.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final base = backend.manuscript.effectiveBase(bookId);
    final raw = await api.effectiveStructureText(
      sourceId: book.source!.sourceId,
      revision: book.source!.revision,
      settingsJson: base['structure'] == null
          ? ''
          : jsonEncode(base['structure']),
      selectedJson: jsonEncode({
        'kind': 'publication',
        'manual': base['manual'],
        'cleanup': base['cleanup'],
        'post_edits': current
            ? backend.manuscript.effectiveSelection(bookId)
            : postEdits,
        'response_scope': 'context',
        'effective_check': {
          'offset': 0,
          'line': null,
          'repair_focus': null,
          'review': _effectiveReviews(),
          'review_change': null,
          'positions': {'summary': true, 'entry_id': null},
          'category': null,
          'severity': null,
        },
      }),
      offset: 0,
    );
    return ((jsonDecode(raw) as Map)['effective_check'] as Map)['positions']
        as Map;
  }

  @override
  Future<ChapterRepairImpact> repairImpact(ChapterRepairPlan plan) async {
    final candidate = plan.preview;
    if (candidate is! _Candidate) {
      throw const FormatException('修复方案不属于当前会话，请重新生成。');
    }
    check(candidate.page);
    final guard = backend.publicationContext(bookId);
    final history = candidate.history;
    final request =
        ((history['history'] as List)[history['cursor'] as int]
                as Map)['request']
            as Map;
    final before = await _positionsSummary(null, current: true);
    final after = await _positionsSummary(
      request.cast<String, dynamic>(),
      current: false,
    );
    check(candidate.page);
    if (guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('书稿已变化，请重新生成方案。');
    }
    return ChapterRepairImpact(
      nodesBefore: before['node_count'] as int,
      nodesAfter: after['node_count'] as int,
      openBefore: before['open'] as int,
      openAfter: after['open'] as int,
    );
  }

  Future<ChapterIssuePage> _review(
    ChapterPage page,
    int offset, {
    String? id,
    String? evidence,
    String? decision,
    String? category,
    String? severity,
  }) async {
    check(page);
    final stamp = _reviewGuard;
    final book = backend.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final result = jsonDecode(
      await api.reviewFindingsText(
        sourceId: book.source!.sourceId,
        revision: book.source!.revision,
        requestJson: jsonEncode({
          'review': jsonDecode(stamp),
          'offset': offset,
          'category': category,
          'severity': severity,
          if (id != null) ...{
            'finding_id': id,
            'evidence_id': evidence,
            'decision': decision,
          },
        }),
      ),
    ) as Map;
    check(page);
    if (stamp != _reviewGuard) throw const FormatException('审阅结论已变化，请重新检查。');
    if (id != null) {
      backend.change(
        () => backend.manuscript.findingReviews[bookId] =
            (result['review'] as Map).cast<String, dynamic>(),
      );
    }
    final diagnostic = result['diagnostic'] as Map;
    final items = (diagnostic['review_items'] as List)
        .cast<Map>()
        .map(
          (v) => ChapterIssue(
            v['id'] as String,
            v['finding_id'] as String,
            v['title'] as String,
            v['evidence'] as String? ?? '',
            List.unmodifiable((v['source_lines'] as List).cast<int>()),
            (v['review'] as Map?)?['decision'] as String?,
            v['category_reviewed'] == true,
            v['auto_applicable'] == true,
            severity: v['severity'] as String? ?? 'info',
            subtype: v['subtype'] as String?,
          ),
        )
        .toList();
    return _Issues(
      List.unmodifiable(items),
      diagnostic['review_total'] as int,
      offset,
      this,
      page,
      _reviewGuard,
      result['evidence_id'] as String,
      categoryCounts: Map<String, int>.from(
        diagnostic['review_categories'] ?? {},
      ),
      severityCounts: Map<String, int>.from(
        diagnostic['review_severities'] ?? {},
      ),
      filteredCategoryCounts: Map<String, int>.from(
        diagnostic['review_filtered_categories'] ?? {},
      ),
      reviewed: diagnostic['review_reviewed'] as int?,
      unfilteredTotal: diagnostic['review_unfiltered_total'] as int?,
      categoryFilter: category,
      severityFilter: severity,
    );
  }

  _Issues _checkedIssues(ChapterIssuePage page) {
    if (page is! _Issues ||
        !identical(page.owner, this) ||
        page.reviewGuard != _reviewGuard) {
      throw const FormatException('检查结果已变化，请重新检查。');
    }
    check(page.structure);
    return page;
  }

  @override
  Future<ChapterIssuePage> reviewIssue(
    ChapterIssuePage page,
    String id,
    String? decision,
  ) async {
    if (page.effective) {
      if (page is! _EffectiveIssues ||
          !identical(page.owner, this) ||
          page.reviewGuard != _reviewGuard ||
          !page.items.any((i) => i.id == id)) {
        throw const FormatException('检查结果已变化，请重新检查。');
      }
      return _reviewEffective(page, [
        {'id': id, 'evidence_id': page.evidenceId, 'decision': decision},
      ]);
    }
    final checked = _checkedIssues(page);
    if (!page.items.any((i) => i.id == id)) {
      throw const FormatException('请在当前问题页选择项目。');
    }
    return _review(
      checked.structure,
      page.offset,
      id: id,
      category: page.categoryFilter,
      severity: page.severityFilter,
      evidence: checked.evidenceId,
      decision: decision,
    );
  }

  @override
  Future<ChapterIssuePage> reviewIssues(
    ChapterIssuePage page,
    List<String> ids,
    String? decision,
  ) async {
    if (!page.effective ||
        page is! _EffectiveIssues ||
        !identical(page.owner, this) ||
        page.reviewGuard != _reviewGuard) {
      throw const FormatException('检查结果已变化，请重新检查。');
    }
    if (ids.isEmpty || ids.length > 1000) {
      throw const FormatException('一次可标记 1 至 1000 项。');
    }
    return _reviewEffective(page, [
      for (final id in ids)
        {'id': id, 'evidence_id': page.evidenceId, 'decision': decision},
    ]);
  }

  Future<ChapterIssuePage> _reviewEffective(
    _EffectiveIssues page,
    List<Map<String, dynamic>> changes,
  ) async {
    final stamp = _reviewGuard;
    final result = await _effectiveCheck(
      page.structure,
      page.offset,
      category: page.categoryFilter,
      severity: page.severityFilter,
      reviewChange: changes.length == 1 ? changes.single : null,
      reviewChanges: changes.length == 1 ? null : changes,
    );
    if (stamp != _reviewGuard) throw const FormatException('审阅结论已变化，请重新检查。');
    final records = Map<String, dynamic>.from(
      (backend.manuscript.findingReviews[bookId]?['records'] as Map?) ?? {},
    );
    records.removeWhere((key, _) => key.startsWith('effective:'));
    for (final entry in ((result['review'] as Map)['records'] as Map).entries) {
      records['effective:${entry.key}'] = entry.value;
    }
    backend.change(
      () => backend.manuscript.findingReviews[bookId] = {'records': records},
    );
    return _effectiveReport(
      page.structure,
      page.offset,
      result,
      category: page.categoryFilter,
      severity: page.severityFilter,
    );
  }

  @override
  Future<ChapterIssueContext> issueContext(
    ChapterIssuePage page,
    ChapterIssue issue, {
    int anchor = 0,
  }) async {
    if (anchor < 0 ||
        anchor >= issue.lines.length ||
        !page.items.contains(issue)) {
      throw const FormatException('请选择当前问题中的文本位置。');
    }
    final ChapterPage tree;
    if (page is _EffectiveIssues) {
      if (!identical(page.owner, this)) {
        throw const FormatException('请重新检查当前草稿。');
      }
      tree = page.structure;
    } else {
      tree = _checkedIssues(page).structure;
    }
    final result = await _effectiveCheck(
      tree,
      page.offset,
      line: page.effective
          ? (anchor < issue.anchors.length
                ? issue.anchors[anchor].line
                : issue.lines[anchor])
          : null,
      originalLine: page.effective ? null : issue.lines[anchor],
      contextOnly: true,
      category: page.categoryFilter,
      severity: page.severityFilter,
    );
    if (page is _EffectiveIssues &&
        result['composition_id'] != page.compositionId) {
      throw const FormatException('书稿已变化，请重新检查。');
    }
    List<ChapterContextRow> rows(Object? values) => [
      for (final row in (values as List? ?? const []).cast<Map>())
        ChapterContextRow(
          row['text'] as String,
          line: row['line'] as int?,
          originalLine: row['original_line'] as int?,
          anchor: row['anchor'] as String?,
          truncated: row['truncated'] == true,
        ),
    ];
    var current = rows(result['excerpt']);
    if (page.effective && anchor < issue.anchors.length) {
      final boundary = issue.anchors[anchor];
      current = current
          .where(
            (row) =>
                row.line == null ||
                ((boundary.startLine == null ||
                        row.line! >= boundary.startLine!) &&
                    (boundary.endLine == null ||
                        row.line! <= boundary.endLine!)),
          )
          .toList();
    }
    if (issue.lines.length == 2 && issue.category == 'number-gap') {
      current = current
          .where(
            (r) =>
                r.line == null ||
                (anchor == 0
                    ? r.line! < issue.lines[1]
                    : r.line! >= issue.lines[1]),
          )
          .toList();
    }
    final original = rows(result['original_excerpt']);
    return ChapterIssueContext(
      rows: current,
      originalRows: original,
      compositionId: result['composition_id'] as String?,
      originalLine: result['context_original_line'] as int?,
      effectiveText: page.effective
          ? current.map((r) => r.text).join('\n')
          : null,
      originalText: original.isEmpty
          ? null
          : original.map((r) => r.text).join('\n'),
    );
  }

  @override
  Future<String> issueSource(ChapterIssuePage page, ChapterIssue issue) async {
    if (page is _EffectiveIssues) {
      if (!identical(page.owner, this) ||
          !page.items.contains(issue) ||
          issue.lines.isEmpty) {
        throw const FormatException('请重新检查当前草稿。');
      }
      final result = await _effectiveCheck(
        page.structure,
        page.offset,
        line: issue.lines.first,
        category: page.categoryFilter,
        severity: page.severityFilter,
      );
      if (result['composition_id'] != page.compositionId) {
        throw const FormatException('书稿已变化，请重新检查。');
      }
      return (result['excerpt'] as List)
          .cast<Map>()
          .map(
            (r) =>
                '${r['line']}: ${r['text']}${r['truncated'] == true ? '…（本行未显示完整）' : ''}',
          )
          .join('\n');
    }
    _checkedIssues(page);
    if (!page.items.contains(issue) || issue.lines.isEmpty) {
      throw const FormatException('此问题没有可定位的原稿行。');
    }
    final book = backend.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final text = await api.readSourcePageText(
      sourceId: book.source!.sourceId,
      revision: book.source!.revision,
      lineIndex: (issue.lines.first - 3).clamp(0, 0x7fffffff),
      utf8Column: 0,
      limit: 12,
    );
    _checkedIssues(page);
    return text.split('\n').skip(1).join('\n');
  }

  @override
  Future<ChapterEditPreview> preview(ChapterPage page, ChapterEdit edit) async {
    final action = switch (edit) {
      InsertChapterVolume e => {
        'kind': 'insert_volume',
        'entry_id': e.nodeId,
        'title': e.title,
      },
      CreateChapterBoundary e => {
        'kind': 'create_boundary',
        'entry_id': e.nodeId == chapterPrefixNode.id ? null : e.nodeId,
        'line_offset': e.lineOffset,
        'role': 'chapter',
        'depth': e.depth,
        'include_toc': true,
      },
      RemoveDuplicateChapterHeading e => {
        'kind': 'remove_duplicate_heading',
        'entry_id': e.nodeId,
      },
      ExcludeChapterBodyLines e => {
        'kind': 'exclude_body_lines',
        'entry_id': e.nodeId == chapterPrefixNode.id ? null : e.nodeId,
        'first_offset': e.firstOffset,
        'last_offset': e.lastOffset,
      },
      DemoteChapterHeading e => {
        'kind': 'classify',
        'entry_id': e.nodeId,
        'role': 'body',
        'depth': 0,
        'include_toc': false,
      },
      RenameChapter e => {
        'kind': 'rename',
        'entry_id': e.nodeId,
        'title': e.title,
      },
      MoveChapterIntoVolume e => {
        'kind': 'move_into_volume',
        'entry_id': e.nodeId,
        'volume_id': e.volumeId,
        'at_start': e.atStart,
      },
      SplitChapter e => {
        'kind': 'split',
        'entry_id': e.nodeId,
        'line_offset': e.lineOffset,
        'title': e.title,
      },
      MergeChapter e => {
        'kind': 'merge_into',
        'entry_id': e.nodeId,
        'target_id': e.targetId,
      },
      MoveChapter e => {
        'kind': 'move_subtree',
        'entry_id': e.nodeId,
        'before_id': e.beforeId,
      },
    };
    return _previewCommand(
      page,
      edit is MergeChapter && edit.title != null
          ? {
              'op': 'append_batch',
              'actions': [
                action,
                {
                  'kind': 'rename',
                  'entry_id': edit.targetId,
                  'title': edit.title,
                },
              ],
            }
          : {'op': 'append', 'action': action},
    );
  }

  @override
  int get pendingEditActions =>
      (backend.manuscript.effectiveSelection(bookId)?['actions'] as List?)
          ?.length ??
      0;

  @override
  Future<ChapterEditPreview> previewCheckpoint(ChapterPage page) {
    final directory = backend.settingsDirectory;
    if (directory == null) {
      throw const FormatException('请先完成工作区设置，再生成编辑检查点。');
    }
    return _previewCommand(page, {
      'op': 'checkpoint',
      'directory': '$directory/edit-checkpoints',
    });
  }

  @override
  Future<ChapterEditPreview> previewCurrentCopy(ChapterPage page) =>
      _previewCommand(page, {'op': 'inspect'});

  Future<ChapterEditPreview> _previewCommand(
    ChapterPage page,
    Map<String, dynamic> command,
  ) async {
    check(page);
    _pending = null;
    final added = command['op'] == 'append'
        ? 1
        : command['op'] == 'append_batch'
        ? (command['actions'] as List).length
        : 0;
    if (added > 0 && page.editBudget?.canAppend == false) {
      throw const FormatException('本书正文较大，本段编辑容量不足，请先生成编辑检查点后重试。');
    }
    if (added > 0 && pendingEditActions + added > 100) {
      throw const FormatException('本段编辑记录容量不足，请先在章节页生成编辑检查点后重试。');
    }
    final ticket = ++_previewGeneration;
    final book = backend.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final base = backend.manuscript.effectiveBase(bookId);
    final result = jsonDecode(
      await api
          .editEffectiveDraft(
            sourceId: book.source!.sourceId,
            revision: book.source!.revision,
            baseJson: jsonEncode(base),
            draftJson: backend.manuscript.effectiveHistories[bookId] == null
                ? ''
                : jsonEncode(backend.manuscript.effectiveHistories[bookId]),
            commandJson: jsonEncode(command),
          )
          .catchError((Object error) async {
            if (error is! api.ApiError) throw error;
            final detail =
                jsonDecode(await api.describeApiError(error: error)) as Map;
            if (detail['operation'] == 'effective_edit' &&
                detail['next_action'] == 'reduce_edit_batch') {
              throw const FormatException('本次编辑超出正文处理容量，请先生成检查点或减少批量编辑数量。');
            }
            if (detail['operation'] == 'effective_repair') {
              throw const FormatException(
                '此标题不符合安全移除条件：须与紧邻的前一标题相同，且前一标题没有正文。请查看问题或选择合并。',
              );
            }
            throw const FormatException('章节预览未通过校验，请检查选中位置和当前结构后重试。原稿及草稿未修改。');
          }),
    ) as Map;
    check(page);
    if (result['matches_current'] != true || ticket != _previewGeneration) {
      throw const ChapterStateChanged('候选结构已过期。');
    }
    return _pending = _Candidate(
      page,
      base,
      (result['history'] as Map).cast<String, dynamic>(),
    );
  }

  Future<ChapterEditPreview> prepareActions(
    ChapterPage page,
    List<dynamic> actions,
  ) => _previewCommand(page, {'op': 'append_batch', 'actions': actions});

  Future<ChapterEditPreview> prepareCatalog(
    ChapterPage page,
    Map<String, dynamic> selection,
  ) => _previewCommand(page, {'op': 'append_catalog', 'catalog': selection});

  _Candidate _candidate(ChapterEditPreview preview) {
    if (!identical(preview, _pending) || preview is! _Candidate) {
      throw const FormatException('请重新生成编辑预览。');
    }
    check(preview.page);
    return preview;
  }

  @override
  Future<ChapterPage> volumes(
    ChapterPage page,
    int offset, {
    String? volumeId,
  }) async {
    check(page);
    final response = await _view(offset, {
      'volume_navigation': {'volume_id': volumeId},
    });
    check(page);
    final result = response['volume_navigation'] as Map;
    return ChapterPage(
      List.unmodifiable(
        (result['nodes'] as List).cast<Map>().map(
          (n) => ChapterNode(
            n['entry_id'] as String,
            n['title'] as String,
            n['role'] as String,
            n['depth'] as int,
            n['source_line'] as int,
            n['include_toc'] as bool,
          ),
        ),
      ),
      result['total'] as int,
      offset,
      page.guard,
    );
  }

  Future<Map> readCandidate(
    ChapterEditPreview preview,
    int offset, {
    String? nodeId,
    int bodyOffset = 0,
  }) async {
    final c = _candidate(preview);
    final book = backend.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    final raw = await api.effectiveStructureText(
      sourceId: book.source!.sourceId,
      revision: book.source!.revision,
      settingsJson: c.base['structure'] == null
          ? ''
          : jsonEncode(c.base['structure']),
      selectedJson: jsonEncode({
        'kind': 'publication',
        'manual': c.base['manual'],
        'cleanup': c.base['cleanup'],
        'post_edits': c.history['history'][c.history['cursor']]['request'],
        if (nodeId != null)
          'body_preview': {'entry_id': nodeId, 'offset': bodyOffset},
      }),
      offset: offset,
    );
    _candidate(preview);
    return jsonDecode(raw) as Map;
  }

  @override
  Future<ChapterPage> previewTree(
    ChapterEditPreview preview,
    int offset,
  ) async {
    final result = await readCandidate(preview, offset);
    return ChapterPage(
      List.unmodifiable(
        (result['nodes'] as List).cast<Map>().map(
          (n) => ChapterNode(
            n['entry_id'] as String,
            n['title'] as String,
            n['role'] as String,
            n['depth'] as int,
            n['source_line'] as int,
            n['include_toc'] as bool,
          ),
        ),
      ),
      result['total'] as int,
      offset,
      _candidate(preview).page.guard,
    );
  }

  @override
  Future<ChapterBody> previewBody(
    ChapterEditPreview preview,
    String nodeId,
    int offset,
  ) async {
    final result = await readCandidate(
      preview,
      0,
      nodeId: nodeId,
      bodyOffset: offset,
    );
    return parseBody(result['body_preview'] as Map, offset);
  }

  @override
  Future<ChapterRepairComparison> previewComparison(
    ChapterRepairPlan plan,
    ChapterRepairChange change, {
    int beforeOffset = 0,
    int afterOffset = 0,
    int beforeCharOffset = 0,
    int afterCharOffset = 0,
  }) async {
    final candidate = _candidate(plan.preview);
    final book = backend.shelf.books.firstWhere((b) => b.id == bookId);
    final cursor = candidate.history['cursor'] as int;
    final response = jsonDecode(
      await api.editEffectiveDraft(
        sourceId: book.source!.sourceId,
        revision: book.source!.revision,
        baseJson: jsonEncode(candidate.base),
        draftJson: jsonEncode(candidate.history),
        commandJson: jsonEncode({
          'op': 'inspect_comparison',
          'before_version': cursor - 1,
          'after_version': cursor,
          'entry_id': change.entryId,
          'line': change.line,
          'kept_line': change.keptLine,
          'before_offset': beforeOffset,
          'after_offset': afterOffset,
          'before_char_offset': beforeCharOffset,
          'after_char_offset': afterCharOffset,
        }),
      ),
    ) as Map;
    _candidate(plan.preview);
    ChapterComparisonSide side(Map value) => ChapterComparisonSide(
      title: value['title'] as String,
      offset: value['offset'] as int,
      totalRows: value['total_rows'] as int,
      focusLine: value['focus_line'] as int?,
      nextOffset: value['next_offset'] as int?,
      nextCharOffset: value['next_char_offset'] as int? ?? 0,
      rows: [
        for (final row in (value['rows'] as List).cast<Map>())
          ChapterContextRow(
            row['text'] as String,
            line: row['line'] as int?,
            originalLine: row['original_line'] as int?,
            anchor: row['anchor'] as String?,
            truncated: row['truncated'] == true,
          ),
      ],
      nodes: [
        for (final node in (value['nodes'] as List).cast<Map>())
          ChapterNode(
            node['entry_id'] as String,
            node['title'] as String,
            node['role'] as String,
            node['depth'] as int,
            node['source_line'] as int,
            node['include_toc'] as bool,
          ),
      ],
    );
    final comparison = response['comparison'] as Map;
    return ChapterRepairComparison(
      side(comparison['before'] as Map),
      side(comparison['after'] as Map),
      retainedCopy: comparison['retained_copy'] == true,
    );
  }

  @override
  Future<ChapterCopyReceipt> exportCopy(
    ChapterEditPreview preview,
    String outputPath,
  ) async {
    final c = _candidate(preview);
    final book = backend.shelf.books.firstWhere((b) => b.id == bookId);
    final result = jsonDecode(
      await api.catalogRequestText(
        cookie: '',
        request: jsonEncode({
          'op': 'export_repair_copy',
          'source_id': book.source!.sourceId,
          'revision': book.source!.revision,
          'source_path': book.source!.path,
          'output_path': outputPath,
          'history': c.history,
          'project': backend.projectDocument(),
          'confirmed': true,
        }),
      ),
    ) as Map;
    if (result['error'] != null) {
      throw FormatException(
        result['reason'] == 'choose_new_output_path'
            ? '目标 TXT 或配套项目已存在，请换一个文件名。'
            : '未能保存修订副本：${result['reason']}',
      );
    }
    return ChapterCopyReceipt(
      result['output_path'] as String,
      result['project_path'] as String,
      (((result['recheck'] as Map)['report'] as Map)['diagnostic']
              as Map)['review_total']
          as int,
    );
  }

  @override
  Future<void> confirm(ChapterEditPreview preview) async {
    final c = _candidate(preview);
    _pending = null;
    backend.change(
      () => backend.manuscript.effectiveHistories[bookId] = c.history,
    );
    _lastConfirmed = c;
    _confirmedGuard = backend.publicationContext(bookId);
  }

  @override
  Future<void> undoConfirmed(ChapterEditPreview preview) async {
    if (!identical(preview, _lastConfirmed) ||
        _confirmedGuard != backend.publicationContext(bookId)) {
      throw const FormatException('草稿已变化，请在章节页核对当前历史后撤销。');
    }
    await backend.manuscript.editEffectiveDraft(bookId, {
      'op': 'undo',
    }, requireMatching: true);
    _lastConfirmed = null;
    _confirmedGuard = null;
  }

  @override
  bool get canUndo =>
      (backend.manuscript.effectiveHistories[bookId]?['cursor'] as int? ?? 0) >
      0;
  @override
  bool get canRedo {
    final history = backend.manuscript.effectiveHistories[bookId];
    return history != null &&
        (history['cursor'] as int) + 1 < (history['history'] as List).length;
  }

  void check(ChapterPage page) {
    if (page.guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('书稿已变化，请刷新章节后重试。');
    }
  }

  ChapterPage? _outline;
  @override
  Future<ChapterPage> readOutline() async {
    final cached = _outline;
    if (cached != null && cached.guard == backend.publicationContext(bookId)) {
      return cached;
    }
    final result = await read(0, fullOutline: true);
    if (result.nodes.length != result.total) {
      throw const FormatException('章节目录未读取完整，请刷新后重试。');
    }
    _outline = result;
    return result;
  }

  @override
  Future<ChapterPage> read(
    int offset, {
    bool includeBody = false,
    String? preferredNodeId,
    bool fullOutline = false,
  }) async {
    final guard = backend.publicationContext(bookId);
    final result = await _view(offset, {
      if (fullOutline) 'outline': true,
      if (includeBody)
        'body_preview': {
          'entry_id': preferredNodeId,
          'offset': 0,
          'select_page': true,
          'focus_page': true,
        },
    });
    if (guard != backend.publicationContext(bookId)) {
      throw const ChapterStateChanged('书稿已变化，请刷新。');
    }
    return ChapterPage(
      List.unmodifiable(
        (result['nodes'] as List).cast<Map>().map(
          (node) => ChapterNode(
            node['entry_id'] as String,
            node['title'] as String,
            node['role'] as String,
            node['depth'] as int,
            node['source_line'] as int,
            node['include_toc'] as bool,
          ),
        ),
      ),
      result['total'] as int,
      result['offset'] as int,
      guard,
      body: result['body_preview'] == null
          ? null
          : parseBody(result['body_preview'] as Map, 0),
      bodyNodeId: (result['body_preview'] as Map?)?['entry_id'] as String?,
      editBudget: result['edit_budget'] is Map
          ? ChapterEditBudget(
              result['edit_budget']['replay_bytes'] as int,
              result['edit_budget']['next_action_bytes'] as int,
              result['edit_budget']['limit_bytes'] as int,
            )
          : null,
    );
  }

  @override
  Future<ChapterBody> body(ChapterPage page, String nodeId, int offset) async {
    check(page);
    final result = await _view(page.offset, {
      'response_scope': 'context',
      'body_preview': {'entry_id': nodeId, 'offset': offset},
    });
    check(page);
    return parseBody(result['body_preview'] as Map, offset);
  }

  static ChapterBody parseBody(Map body, int offset) {
    return ChapterBody(
      List.unmodifiable(
        (body['rows'] as List).cast<Map>().map(
          (row) =>
              '${row['text']}${row['truncated'] == true ? '…（本行预览已截断）' : ''}',
        ),
      ),
      offset,
      body['total'] as int,
      body['has_more'] as bool,
      rows: List.unmodifiable(
        (body['rows'] as List).cast<Map>().map(
          (row) => ChapterBodyRow(
            row['text'] as String,
            row['line_offset'] as int,
            row['selectable'] == true,
            nextCharOffset: row['next_char_offset'] as int?,
            outputLine: row['source_line'] as int?,
          ),
        ),
      ),
    );
  }

  @override
  Future<ChapterBodyRow> bodyLine(
    ChapterPage page,
    String nodeId,
    int offset,
    int charOffset,
  ) async {
    check(page);
    final result = await _view(page.offset, {
      'response_scope': 'context',
      'body_preview': {
        'entry_id': nodeId,
        'offset': offset,
        'char_offset': charOffset,
      },
    });
    check(page);
    return parseBody(result['body_preview'] as Map, offset).rows.single;
  }

  @override
  Future<void> rename(ChapterPage page, String nodeId, String title) async {
    check(page);
    await backend.manuscript.editEffectiveDraft(bookId, {
      'op': 'append',
      'action': {'kind': 'rename', 'entry_id': nodeId, 'title': title},
    });
  }

  @override
  Future<void> properties(
    ChapterPage page,
    ChapterNode node, {
    String? role,
    bool? inToc,
  }) async {
    check(page);
    await backend.manuscript.editEffectiveDraft(bookId, {
      'op': 'append',
      'action': {
        'kind': 'classify',
        'entry_id': node.id,
        'role': role ?? node.role,
        'depth': node.depth,
        'include_toc': inToc ?? node.inToc,
      },
    });
  }

  @override
  Future<void> history(ChapterPage page, {required bool undo}) async {
    check(page);
    await backend.manuscript.editEffectiveDraft(bookId, {
      'op': undo ? 'undo' : 'redo',
    }, requireMatching: true);
  }
}

class _Candidate extends ChapterEditPreview {
  const _Candidate(this.page, this.base, this.history);
  final ChapterPage page;
  final Map<String, dynamic> base, history;
}

class _Issues extends ChapterIssuePage {
  const _Issues(
    super.items,
    super.total,
    super.offset,
    this.owner,
    this.structure,
    this.reviewGuard,
    this.evidenceId, {
    super.categoryCounts,
    super.severityCounts,
    super.categoryFilter,
    super.severityFilter,
    super.filteredCategoryCounts,
    super.reviewed,
    super.unfilteredTotal,
  });
  final LegacyChapterSession owner;
  final ChapterPage structure;
  final String reviewGuard, evidenceId;
}

class _EffectiveIssues extends ChapterIssuePage {
  const _EffectiveIssues(
    super.items,
    super.total,
    super.offset,
    this.owner,
    this.structure,
    this.compositionId,
    this.evidenceId,
    this.reviewGuard, {
    super.categoryCounts,
    super.severityCounts,
    super.categoryFilter,
    super.severityFilter,
    super.filteredCategoryCounts,
    super.reviewed,
    super.unfilteredTotal,
  }) : super(effective: true);
  final LegacyChapterSession owner;
  final ChapterPage structure;
  final String compositionId, evidenceId, reviewGuard;
}

class _RepairOptions extends ChapterRepairOptions {
  const _RepairOptions(
    super.changes,
    super.total,
    super.report,
    this.owner,
    this.page,
    this.commands,
  );
  final LegacyChapterSession owner;
  final ChapterPage page;
  final Map<String, List<dynamic>> commands;
}
