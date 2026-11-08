import '../application/cleanup_rule_resolution.dart';
import '../application/conversion_snapshot.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../application/book_check_service.dart';
import '../application/library_service.dart' show BookPendingSummary;
import '../application/chapter_service.dart';
import '../application/cleanup_service.dart' show CleanupInspection;
import '../prototype/prototype_state.dart';
import 'check_report_cache.dart';
import 'atomic_file.dart';
import 'legacy_cleanup_session.dart';
import 'legacy_chapter_session.dart';
import 'legacy_resource_session.dart';

class LegacyBookCheckSession extends ChangeNotifier
    implements
        BookCheckSession,
        CachedBookCheckSession,
        CheckUpdateSession,
        BookCheckProgressSession {
  LegacyBookCheckSession(this.backend, this.bookId) {
    _guard = _context();
    _seenReport = _reports[backend]?[bookId];
    backend.addListener(_refresh);
  }
  static final _reports = Expando<Map<String, BookCheckReport>>();

  /// 按稿件版本缓存的检查指纹（LIB-114）：书 → (稿件版本 + 清理规则标识, 指纹)。
  static final _guards = Expando<Map<String, (String, String)>>();

  /// 已确认磁盘上没有报告文件的指纹（LIB-114）：书 → 指纹。
  static final _missing = Expando<Map<String, String>>();

  /// 每一项的版本：书 → (稿件版本 + 清理规则标识, 各项版本)。
  static final _domainGuards =
      Expando<Map<String, (String, Map<String, String>)>>();

  /// 正在进行的更新：同一本书只跑一份，书库的后台重查和页面共用它。
  static final _updates = Expando<Map<String, Future<BookCheckReport>>>();

  /// 文本问题的位置：书 → (文本那一项的版本, 位置)。不写进报告文件，书库列表读报告时
  /// 不用带它；另存一个二进制文件，重启后不用再跑清理。
  static final _spots = Expando<Map<String, (String, CheckSpots)>>();

  /// 书籍信息只看这几个字段。
  static const _metadataFields = ['title', 'author', 'language', 'cover_path'];

  /// 算每一项的版本。章节和文本只取决于书稿，书籍信息只取决于几个字段，
  /// 图片还要看全部制作设置；改一项不会牵动不相干的项。
  static Map<String, String> guardsFor(PrototypeState backend, String id) {
    final rules = resolveCleanupRules(
      backend.globalConfiguration,
      bookDraft: backend.cleanup.drafts[id],
      pendingPipeline:
          backend.production.drafts[id]?.ruleOptions['cleanup_pipeline']
              as List?,
    ).fingerprint;
    final key = '${backend.publicationContext(id)}\u0000$rules';
    final pipeline = resolveCleanupRules(
      backend.globalConfiguration,
      bookDraft: backend.cleanup.drafts[id],
      pendingPipeline:
          backend.production.drafts[id]?.ruleOptions['cleanup_pipeline']
              as List?,
    ).pipelineKey;
    final cache = _domainGuards[backend] ??= {};
    final hit = cache[id];
    if (hit != null && hit.$1 == key) return hit.$2;
    final settings = backend.production.settings(id);
    final text = publicationFingerprint({
      'text': [
        backend.shelf.books.firstWhere((b) => b.id == id).source?.sourceId,
        backend.manuscript.effectiveBase(id),
        backend.manuscript.effectiveSelection(id),
      ],
    });
    final checked = jsonEncode(metadataRulesOf(settings));
    final guards = {
      'chapters': text,
      'cleanup': '$text:$rules',
      'rules': pipeline,
      'metadata_rules': checked,
      'metadata': publicationFingerprint({
        'metadata': [
          for (final field in _metadataFields) settings[field],
          checked,
        ],
      }),
      'resources': publicationFingerprint({
        'resources': [text, settings],
      }),
    };
    cache[id] = (key, guards);
    return guards;
  }

  /// 关掉了哪些书籍信息检查（规则页“输出前检查”）。
  static List<String> metadataRulesOf(Map settings) {
    final off =
        ((settings['rule_options'] as Map?)?['disabled'] as List?) ?? const [];
    return [
      for (final id in const [
        'preflight.author',
        'preflight.cover',
        'preflight.language',
      ])
        if (off.contains(id)) id,
    ];
  }

  /// 书籍信息的问题，直接从设置算。关掉的不算问题；书名是必需项，不能关。
  static List<CheckFinding> metadataFindingsFor(Map settings) {
    final off = metadataRulesOf(settings);
    return [
      ..._metadataFindings(settings)
          .where((f) => !off.contains('preflight.${f.id.split(':').last}')),
    ];
  }

  static List<CheckFinding> _metadataFindings(Map settings) => [
    if ((settings['title'] as String? ?? '').trim().isEmpty)
      const CheckFinding(
        'metadata:title',
        '书名尚未填写',
        '在书籍信息中填写当前成品书名。',
        'metadata',
      ),
    if ((settings['author'] as String? ?? '').trim().isEmpty)
      const CheckFinding(
        'metadata:author',
        '作者尚未填写',
        '可填写作者；明确无作者时也可以保留空值。',
        'metadata',
      ),
    if ((settings['language'] as String? ?? '').trim().isEmpty ||
        settings['language'] == 'und')
      const CheckFinding(
        'metadata:language',
        '书籍语言尚未明确',
        '在书籍信息中明确本书语言；转换时仍按既有规则继承默认值。',
        'metadata',
      ),
    if ((settings['cover_path'] as String? ?? '').isEmpty)
      const CheckFinding(
        'metadata:cover',
        '尚未指定封面',
        '选择图片或生成文字封面；无需封面时可保留。',
        'cover',
      ),
  ];

  /// 检查指纹。[version] 是书库刷新时已经算好的稿件版本
  /// （[PrototypeState.publicationContext]），省去重复计算。
  ///
  /// 稿件版本包含指纹的全部输入（原稿标识、制作设置、结构、人工编辑、清理设置与
  /// 章节修改历史），再加上清理规则的标识作为键：键不变时指纹必然不变，直接复用，
  /// 不再排序、序列化和计算哈希。
  static String contextFor(
    PrototypeState backend,
    String id, {
    String? version,
  }) {
    final rules = resolveCleanupRules(
      backend.globalConfiguration,
      bookDraft: backend.cleanup.drafts[id],
      pendingPipeline:
          backend.production.drafts[id]?.ruleOptions['cleanup_pipeline']
              as List?,
    ).fingerprint;
    final key = '${version ?? backend.publicationContext(id)}\u0000$rules';
    final cache = _guards[backend] ??= {};
    final hit = cache[id];
    if (hit != null && hit.$1 == key) return hit.$2;
    final guard = publicationFingerprint({
      'check': [
        backend.shelf.books.firstWhere((b) => b.id == id).source?.sourceId,
        backend.production.settings(id),
        backend.manuscript.effectiveBase(id),
        backend.manuscript.effectiveSelection(id),
        rules,
      ],
    });
    cache[id] = (key, guard);
    return guard;
  }

  static File? cacheFile(PrototypeState backend, String guard) =>
      backend.settingsDirectory == null
      ? null
      : File(
          '${backend.settingsDirectory}/check-reports/${checkReportFileName(guard)}',
        );
  static BookCheckReport? lookup(PrototypeState backend, String id) =>
      _lookup(backend, id, contextFor(backend, id));
  static BookCheckReport? _lookup(
    PrototypeState backend,
    String id,
    String guard,
  ) {
    final existing = _reports[backend]?[id];
    if (existing?.guard == guard) return existing;
    // 这一稿已确认没有报告文件时不再查磁盘（LIB-114）。检查完成后报告先进内存，
    // 不会走到这里。
    if (_missing[backend]?[id] == guard) return existing;
    try {
      final file = cacheFile(backend, guard);
      if (file != null && !file.existsSync()) {
        (_missing[backend] ??= {})[id] = guard;
      }
      if (file != null && file.existsSync() && file.lengthSync() < 262144) {
        final report = BookCheckReport.fromJson(
          jsonDecode(file.readAsStringSync()) as Map,
        );
        if (report.guard == guard) {
          (_reports[backend] ??= {})[id] = report;
          return report;
        }
      }
    } catch (_) {
      /* An invalid cache is never a successful check. */
    }
    return existing;
  }

  static String? statusFor(PrototypeState backend, String id) =>
      summaryFor(backend, id).status;

  /// 书库显示的状态与待处理数量（LIB-099/100）：只算一次稿件指纹、读一次报告。
  /// 报告不是当前稿的结果时没有数量。
  static ({String? status, BookPendingSummary? pending}) summaryFor(
    PrototypeState backend,
    String id, {
    String? version,
  }) {
    final guard = contextFor(backend, id, version: version);
    final report = _lookup(backend, id, guard);
    if (report == null) return (status: null, pending: null);
    // 稿件变了，或报告格式太旧（CHK-060）：都需要重新检查。
    if (report.guard != guard || report.outdated) {
      return (status: '检查已过期', pending: null);
    }
    final String status;
    if (report.domains.any((d) => d.failed)) {
      status = '检查未完成';
    } else {
      status =
          report.domains.any(
            (d) =>
                d.findings.isNotEmpty ||
                (d.id != 'output' && d.id != 'resources' && d.items.isNotEmpty),
          )
          ? '检查完成 · 有待核对项'
          : '检查通过';
    }
    int? of(String domain) =>
        report.domains.where((d) => d.id == domain).firstOrNull?.count;
    final chapters = of('chapters'), cleanup = of('cleanup');
    final metadata = of('metadata');
    return (
      status: status,
      pending: chapters == null && cleanup == null && metadata == null
          ? null
          : BookPendingSummary(
              chapters: chapters ?? 0,
              cleanup: cleanup ?? 0,
              metadata: metadata ?? 0,
              checkedAt: report.checkedAt,
            ),
    );
  }

  @override
  BookCheckReport? get shown => _bookExists ? lookup(backend, bookId) : null;

  bool get _bookExists =>
      backend.shelf.books.any((b) => b.id == bookId && !b.isDemo);

  @override
  bool domainCurrent(String id) {
    final report = shown;
    if (report == null) return false;
    if (isCurrent(report)) return true;
    final have = report.guards[id];
    return have != null && have == guardsFor(backend, bookId)[id];
  }

  @override
  List<CheckFinding> metadataFindings() => _bookExists
      ? metadataFindingsFor(backend.production.settings(bookId))
      : const [];

  @override
  String get cleanupRulesKey => guardsFor(backend, bookId)['rules']!;

  /// 每一项“查什么”存在报告的哪个键里。
  static const _ruleKeys = {
    'chapters': 'chapter_rules',
    'cleanup': 'rules',
    'metadata': 'metadata_rules',
  };

  @override
  bool rulesCurrent(String id) {
    final report = shown, key = _ruleKeys[id];
    if (report == null || key == null || !_bookExists) return true;
    final now = guardsFor(backend, bookId)[key];
    return now == null || report.guards[key] == now;
  }

  @override
  Set<int> keptCleanupLines() => {
    ...((backend.cleanup.drafts[bookId]?['skip_lines'] as List?) ?? const [])
        .cast<int>(),
  };

  File? _spotsFile(String version) => backend.settingsDirectory == null
      ? null
      : File(
          '${backend.settingsDirectory}/check-reports/${checkSpotsFileName(version)}',
        );

  /// 存不下不影响结果，下次用到时再算。
  Future<void> _storeSpots(String version, CheckSpots spots) async {
    try {
      final file = _spotsFile(version);
      if (file == null) return;
      if (spots.length == 0) {
        if (await file.exists()) await file.delete();
        return;
      }
      await writeAtomicBytes(file, encodeCheckSpots(spots));
    } catch (_) {}
  }

  @override
  Future<CheckSpots?> storedSpots() async {
    if (!_bookExists) return null;
    final want = guardsFor(backend, bookId)['cleanup']!;
    final hit = _spots[backend]?[bookId];
    if (hit != null && hit.$1 == want) return hit.$2;
    try {
      final file = _spotsFile(want);
      if (file == null || !await file.exists()) return null;
      final value = decodeCheckSpots(await file.readAsBytes());
      if (value != null) (_spots[backend] ??= {})[bookId] = (want, value);
      return value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<CheckSpots> spots({List<Map<String, dynamic>>? pipeline}) async {
    final guards = guardsFor(backend, bookId);
    final want = pipeline == null
        ? guards['cleanup']!
        : '${guards['chapters']}:${cleanupPipelineKey(pipeline)}';
    final hit = _spots[backend]?[bookId];
    if (hit != null && hit.$1 == want) return hit.$2;
    if (pipeline == null) {
      if (!_cleanupEnabled) return CheckSpots.empty;
      if (await storedSpots() case final stored?) return stored;
    }
    final cleanup = LegacyCleanupSession(backend, bookId);
    try {
      final report = await cleanup.recheck(positions: true, pipeline: pipeline);
      final value = report.spots ?? CheckSpots.empty;
      (_spots[backend] ??= {})[bookId] = (want, value);
      if (pipeline == null) await _storeSpots(want, value);
      return value;
    } finally {
      cleanup.dispose();
    }
  }

  static List<CleanupCheckItem> _cleanupItems(CleanupInspection report) => [
    for (final f in report.findings)
      CleanupCheckItem(
        f.line,
        f.kind,
        f.before,
        f.after,
        truncated: f.truncated,
        candidate: f.candidate,
      ),
  ];

  @override
  Future<List<CleanupCheckItem>> cleanupItemsAt(int offset) async {
    final cleanup = LegacyCleanupSession(backend, bookId);
    try {
      return _cleanupItems(await cleanup.recheck(offset: offset));
    } finally {
      cleanup.dispose();
    }
  }

  /// 测试用：当成刚重启，内存里没有位置。
  @visibleForTesting
  static void forgetSpots(PrototypeState backend) => _spots[backend]?.clear();

  @override
  Future<BookCheckReport> update() {
    final running = _updates[backend] ??= {};
    if (running[bookId] case final going?) return going;
    final previous = shown;
    if (previous != null && !previous.outdated && isCurrent(previous)) {
      return Future.value(previous);
    }
    final future = previous == null || previous.outdated
        ? inspect()
        : _incremental(previous);
    running[bookId] = future;
    void done() => running.remove(bookId);
    future.then((_) => done(), onError: (_) => done());
    return future;
  }

  Future<BookCheckReport> _incremental(BookCheckReport previous) async {
    checkRunning = true;
    checkCancelling = false;
    try {
      return await _inspect(previous: previous);
    } on ChapterStateChanged {
      // 页面关了：不用再算，也没人要这个错误。
      if (_disposed) return previous;
      rethrow;
    } finally {
      checkRunning = false;
      checkCancelling = false;
      _stage('');
    }
  }

  @override
  BookCheckReport? get latest {
    final report = lookup(backend, bookId);
    return report != null && isCurrent(report) ? report : null;
  }

  bool get _cleanupEnabled => resolveCleanupRules(
    backend.globalConfiguration,
    bookDraft: backend.cleanup.drafts[bookId],
    pendingPipeline:
        backend.production.drafts[bookId]?.ruleOptions['cleanup_pipeline']
            as List?,
  ).enabled;

  final PrototypeState backend;
  final String bookId;
  int generation = 0;
  bool _disposed = false;
  @override
  bool checkRunning = false;
  @override
  bool checkCancelling = false;
  @override
  String checkPhase = '';
  void _stage(String value) {
    checkPhase = value;
    if (!_disposed) notifyListeners();
  }

  late String _guard;
  BookCheckReport? _seenReport;
  String _context() =>
      backend.shelf.books.any((b) => b.id == bookId && !b.isDemo)
      ? contextFor(backend, bookId)
      : '';
  void _refresh() {
    final next = _context();
    final latestReport = _reports[backend]?[bookId];
    if (next == _guard && identical(latestReport, _seenReport)) return;
    _guard = next;
    _seenReport = latestReport;
    notifyListeners();
  }

  @override
  Listenable get changes => this;
  @override
  void dispose() {
    _disposed = true;
    cancel();
    backend.removeListener(_refresh);
    super.dispose();
  }

  @override
  void cancel() {
    generation++;
    if (checkRunning) {
      checkCancelling = true;
      _stage('正在停止，等待当前检查返回…');
    }
  }

  @override
  bool isCurrent(BookCheckReport report) =>
      backend.shelf.books.any((b) => b.id == bookId && !b.isDemo) &&
      report.guard == contextFor(backend, bookId);

  @override
  Future<BookCheckReport> inspect() async {
    if (checkRunning) throw const FormatException('请等待当前检查停止。');
    checkRunning = true;
    checkCancelling = false;
    try {
      return await _inspect();
    } finally {
      checkRunning = false;
      checkCancelling = false;
      _stage('');
    }
  }

  /// [previous] 不为空时只重算对不上书稿的项，每算完一项就放出来，页面的数字跟着变。
  /// 手动检查全部重算，进度从头开始。
  Future<BookCheckReport> _inspect({BookCheckReport? previous}) async {
    final ticket = ++generation;
    final incremental = previous != null;
    final guard = contextFor(backend, bookId);
    void validate() {
      if (ticket != generation ||
          (!incremental && guard != contextFor(backend, bookId))) {
        throw const ChapterStateChanged('检查已取消或草稿已变化，请重新检查。');
      }
    }

    validate();
    final book = backend.shelf.books.firstWhere(
      (b) => b.id == bookId && !b.isDemo,
    );
    if (book.source == null) throw const FormatException('请先导入真实书稿。');
    final domains = <String, CheckDomain>{
      for (final domain in previous?.domains ?? const <CheckDomain>[])
        domain.id: domain,
    };
    final guards = <String, String>{...?previous?.guards};
    ChapterIssue? first = previous?.firstIssue;
    var evidence = previous?.evidence ?? '';
    var safe = previous?.safeRepairs ?? 0;

    /// 要查的东西换了，这一项的问题就是另一批了，进度从头算：关掉的不算问题，
    /// 也不算做完。只采用方案时规则没变，进度留着。
    bool rulesChanged(String id) {
      final key = _ruleKeys[id];
      final before = key == null ? null : previous?.guards[key];
      return before != null && before != guards[key];
    }

    Map<String, int> baseline() => {
      for (final domain in domains.values)
        domain.id: rulesChanged(domain.id)
            ? domain.count ?? 0
            : math.max(
                previous?.baseline[domain.id] ?? 0,
                domain.count ?? domain.findings.length,
              ),
    };
    List<CheckDomain> ordered() => List.unmodifiable([
      for (final id in const [
        'chapters',
        'cleanup',
        'metadata',
        'resources',
        'output',
      ])
        ?domains[id],
    ]);
    BookCheckReport compose(String value) => BookCheckReport(
      value,
      ordered(),
      first,
      evidence,
      safe,
      checkedAt: DateTime.now(),
      bookId: bookId,
      guards: Map.unmodifiable(guards),
      baseline: Map.unmodifiable(baseline()),
    );

    /// 算完一项先放出来：总的版本还是旧的，这一项已经是新的。
    void publish(String id, String version) {
      guards[id] = version;
      if (!incremental) return;
      (_reports[backend] ??= {})[bookId] = compose(previous.guard);
      if (!_disposed) notifyListeners();
    }

    Future<void> chaptersDomain() async {
      _stage('正在检查章节');
      validate();
      try {
        final chapters = LegacyChapterSession(backend, bookId);
        final page = await chapters.read(0);
        validate();
        final options = await chapters.repairs(page);
        validate();
        safe = options.total;
        // 摘录只取有原稿行的问题：“全书未识别标题”没有行号，以前排在第一时整个章节检查会失败（V113）。
        final located = options.report.items.where((i) => i.lines.isNotEmpty);
        first =
            located.where((i) => i.autoApplicable).firstOrNull ??
            located.firstOrNull;
        evidence = first == null
            ? ''
            : await chapters.issueSource(options.report, first!);
        validate();
        domains['chapters'] = CheckDomain(
          'chapters',
          '章节结构',
          options.report.total == 0 ? '未发现问题' : '${options.report.total} 项待核对',
          '当前有效草稿 · $safe 项有安全修复候选',
          List.unmodifiable(options.report.items.map((i) => i.title)),
          count: options.report.total,
        );
        final tree = await backend.manuscript.effectiveTree(bookId, 0);
        validate();
        guards['chapter_rules'] = jsonEncode(
          (tree['recognition_rules'] as Map?)?['disabled_checks'] ?? const [],
        );
      } catch (e) {
        validate();
        first = null;
        evidence = '';
        safe = 0;
        domains['chapters'] = const CheckDomain(
          'chapters',
          '章节结构',
          '检查失败',
          '无法读取当前有效结构；不能视为无问题。',
          [],
          failed: true,
        );
      }
    }

    Future<void> cleanupDomain(String version) async {
      _stage('正在检查文本清理');
      validate();
      try {
        final cleanup = LegacyCleanupSession(backend, bookId);
        final report = await (() async {
          try {
            return await cleanup.recheck(positions: true);
          } finally {
            cleanup.dispose();
          }
        })();
        validate();
        if (report.spots case final spots?) {
          (_spots[backend] ??= {})[bookId] = (version, spots);
          await _storeSpots(version, spots);
        }
        domains['cleanup'] = CheckDomain(
          'cleanup',
          '文本清理',
          _cleanupEnabled
              ? '${report.changes} 处清理建议 · ${report.candidates} 条广告候选'
              : '未启用',
          '按已选择的检测规则检查当前稿',
          report.evidence,
          count: _cleanupEnabled ? report.changes + report.candidates : 0,
          cleanup: _cleanupItems(report),
        );
      } catch (e) {
        validate();
        domains['cleanup'] = const CheckDomain(
          'cleanup',
          '文本清理',
          '检测失败',
          '规则或源范围无法生成预览，现有设置未改变。',
          [],
          failed: true,
        );
      }
    }

    void metadataDomain() {
      _stage('正在检查书籍信息');
      validate();
      final missing = metadataFindings();
      guards['metadata_rules'] = guardsFor(backend, bookId)['metadata_rules']!;
      domains['metadata'] = CheckDomain(
        'metadata',
        '书籍信息',
        missing.isEmpty ? '字段齐全' : '${missing.length} 项待补充',
        '当前制作设置 · 图片可读性由资源检查核验',
        List.unmodifiable(missing.map((f) => f.title)),
        findings: List.unmodifiable(missing),
        count: missing.length,
      );
    }

    Future<void> resourcesDomain() async {
      _stage('正在检查图片与排版资源');
      validate();
      final settings = backend.production.settings(bookId);
      try {
        final resources = await backend.production.publicationResources(bookId);
        validate();
        final manifest = resources['manifest'] as Map;
        domains['resources'] = CheckDomain(
          'resources',
          '图片资源',
          '引用检查通过',
          '当前有效稿资源与正文位置已核验',
          [
            '${(manifest['resources'] as List).length} 项图像资源',
            '${(manifest['placements'] as List).length} 处正文插图位置',
          ],
        );
      } catch (e) {
        validate();
        final findings = <CheckFinding>[];
        final resources = LegacyResourceSession(backend, bookId);
        try {
          final rows = await resources.read();
          validate();
          for (final row in rows.where((row) => row.error.isNotEmpty)) {
            // Unused imported inventory does not block the current publication.
            if (row.kind.startsWith('epub-')) continue;
            findings.add(
              CheckFinding(
                'resource:${row.index}:unreadable',
                row.index == -1 ? '封面图片不可用' : '${row.location}：${row.name}',
                '${row.error}\n${row.path}',
                'resources',
                severity: 'error',
              ),
            );
          }
          final positions = await backend.production.illustrationPositions(
            bookId,
          );
          validate();
          for (var i = 0; i < positions.length; i++) {
            final status = positions[i]['status'];
            if (status != 'unplaced' && status != 'needs_relocation') continue;
            final image = (settings['illustrations'] as List)[i] as Map;
            findings.add(
              CheckFinding(
                'resource:$i:$status',
                '第 ${i + 1} 张插图${status == 'unplaced' ? '未设置位置' : '需要重新定位'}',
                '${status == 'unplaced' ? '请选择正文插入行。' : '原插入行已在编辑中移除，请重新选择有效位置。'}\n${image['path']}',
                'resources',
                severity: 'error',
              ),
            );
          }
        } catch (_) {
          validate();
        } finally {
          resources.dispose();
        }
        // Always retain the failed combined check: individual findings may not
        // explain all layout/CSS/font or composition errors in the publication.
        findings.add(
          const CheckFinding(
            'resources:combined',
            '成品资源组合校验未通过',
            '请处理列出的问题后重新检查；若仍未通过，请检查图片位置及排版中的CSS、字体设置。',
            'resources',
            severity: 'error',
          ),
        );
        domains['resources'] = CheckDomain(
          'resources',
          '图片资源',
          '检查未通过',
          '资源、锚点或制作设置未通过组合校验；不能当作图片无问题。',
          List.unmodifiable(findings.map((f) => f.title)),
          failed: true,
          findings: List.unmodifiable(findings),
        );
      }
    }

    domains['output'] = const CheckDomain(
      'output',
      '目标格式',
      '转换时检查',
      '选定输出格式、目标位置后，按转换批次检查',
      [],
    );
    // 书籍信息最快，先出来；算的过程中书稿又变了，只把变了的项再算一遍。
    for (var pass = 0; ; pass++) {
      final now = guardsFor(backend, bookId);
      bool stale(String id) =>
          !incremental || guards[id] != now[id] || !domains.containsKey(id);
      if (!(stale('chapters') ||
          stale('cleanup') ||
          stale('metadata') ||
          stale('resources'))) {
        break;
      }
      if (pass >= 3) {
        throw const ChapterStateChanged('检查已取消或草稿已变化，请重新检查。');
      }
      if (incremental) {
        if (stale('metadata')) {
          metadataDomain();
          publish('metadata', now['metadata']!);
        }
        if (stale('chapters')) {
          await chaptersDomain();
          publish('chapters', now['chapters']!);
        }
        if (stale('cleanup')) {
          await cleanupDomain(now['cleanup']!);
          guards['rules'] = now['rules']!;
          publish('cleanup', now['cleanup']!);
        }
        if (stale('resources')) {
          await resourcesDomain();
          publish('resources', now['resources']!);
        }
      } else {
        await chaptersDomain();
        publish('chapters', now['chapters']!);
        await cleanupDomain(now['cleanup']!);
        guards['rules'] = now['rules']!;
        publish('cleanup', now['cleanup']!);
        metadataDomain();
        publish('metadata', now['metadata']!);
        await resourcesDomain();
        publish('resources', now['resources']!);
        break;
      }
    }
    validate();
    final finalGuard = incremental ? contextFor(backend, bookId) : guard;
    final report = compose(finalGuard);
    (_reports[backend] ??= {})[bookId] = report;
    try {
      final file = cacheFile(backend, finalGuard);
      if (file != null) {
        await file.parent.create(recursive: true);
        await writeAtomicText(file, jsonEncode(report.toJson()));
      }
    } catch (_) {
      /* Cache persistence does not change the diagnosis. */
    }
    validate();
    backend.change(() {}, bookIds: {bookId});
    return report;
  }
}
