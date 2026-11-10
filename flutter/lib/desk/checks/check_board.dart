// 检查进度（docs/42）：检查页和章节、文本、信息这些页面读同一份问题。
// 这里只存“还没处理的问题在哪里”：章节问题是报告里的位置，文本问题是行号，都是整数列表，
// 问题内容要看时才按页读。走到下一条、点格子、拖动都是常数时间，问题上万条也不用等。
// 页面只提供“就地显示”的钩子，地址跳转留给页面不在时。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../application/book_check_service.dart';
import '../../application/chapter_service.dart';
import '../../application/cleanup_rule_resolution.dart';
import '../../application/cleanup_service.dart';
import '../../application/library_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../shell/page_menu.dart';

/// 进度条出现的页面，以及它们各自管哪一段。
const checkBoardPages = <String, String?>{
  '检查与修复': null,
  '章节编辑': 'chapters',
  '文本清理': 'cleanup',
  '书籍信息': 'metadata',
  '图片与资源': 'resources',
};

/// 一段：章节、文本、信息、图片。图片问题很少，有才显示。
class CheckTrack {
  const CheckTrack(this.id, this.label, this.total, this.pending);
  final String id, label;
  final int total, pending;
  int get done => (total - pending).clamp(0, total);
}

/// 第几段的第几条还没处理的问题。
typedef CheckCell = ({String track, int index});

class CheckBoard extends ChangeNotifier {
  CheckBoard({
    required this.library,
    required this.go,
    required this.location,
    required this.showChapterIssue,
    required this.showChecks,
  });
  final LibraryService library;

  /// 跳到另一个页面。
  final void Function(String location) go;

  /// 当前地址，用来保留“从转换页来”这样的标记。
  final Uri Function() location;

  /// 打开章节编辑的“问题”页签并选中这一条（页面不在时）。
  final void Function(String book, String issueId, int offset) showChapterIssue;

  /// 回到检查页的这个页签。
  final void Function(String book, String? domain) showChecks;

  /// 书稿停下来多久后更新问题。
  static const refreshDelay = Duration(milliseconds: 500);

  /// 同时留几页问题内容（每页 50 条）。
  static const _keptPages = 4;

  String? bookId, page;
  List<CheckTrack> tracks = const [];
  CheckCell? selected;

  /// 后台正在更新，数字可能还会变。
  bool updating = false;

  /// 问题数量变了才响。检查页只听这个：走到下一条时不用重建整个页面。
  final counts = ValueNotifier<int>(0);

  /// 用户关掉了：这次打开期间不再自己出现。
  final _dismissed = <String>{};

  /// 这个页面上全部做完了：留着“回到检查”，离开页面后消失。
  bool _finished = false;
  bool _ready = false, _disposed = false;

  BookCheckSession? _checks;
  ChapterSession? _chapters;
  ChapterPage? _structure;
  Int32List _queue = Int32List(0);
  String? _queueGuard;
  final _pages = <int, ChapterIssuePage>{};
  final _loading = <int, Future<ChapterIssuePage?>>{};

  CheckSpots? _spots;
  String? _spotsGuard;

  /// 清理页里还没采用的规则：和已保存的规则不同时才有。这时文本问题按它算，进度从头算。
  List<Map<String, dynamic>>? _draftRules;
  String? _draftKey;
  Timer? _draftTimer;

  /// 文本位置还没读时要站到的行。
  int? _wantLine;

  /// 还没处理的文本问题：[_spots] 的下标。
  Int32List _open = Int32List(0);
  bool _spotsLoading = false;

  List<CheckFinding> _metadata = const [], _resources = const [];
  BookCheckReport? _report;

  int _ticket = 0;
  Timer? _refresh;
  bool _updateRunning = false, _updateAgain = false;
  int _failures = 0;

  // 页面钩子：页面在时就地显示，不走路由。
  void Function(String id, int offset)? _showIssue;
  bool Function(int line)? _showLine;
  bool Function(int line)? _keepLine;
  void Function(String field)? _showField;
  void Function(String id)? _showResource;
  void Function(String domain)? _showDomain;

  CheckUpdateSession? get _updates =>
      _checks is CheckUpdateSession ? _checks as CheckUpdateSession : null;

  void attachIssues(void Function(String id, int offset) show) =>
      _showIssue = show;
  void detachIssues(void Function(String id, int offset) show) {
    if (_showIssue == show) _showIssue = null;
  }

  void attachCleanup(bool Function(int) show, bool Function(int) keep) {
    _showLine = show;
    _keepLine = keep;
    notifyListeners();
  }

  void detachCleanup(bool Function(int) show) {
    if (_showLine != show) return;
    _showLine = null;
    _keepLine = null;
  }

  void attachField(void Function(String field) show) => _showField = show;
  void detachField(void Function(String field) show) {
    if (_showField == show) _showField = null;
  }

  void attachResources(void Function(String id) show) => _showResource = show;
  void detachResources(void Function(String id) show) {
    if (_showResource == show) _showResource = null;
  }

  void attachDomains(void Function(String domain) show) => _showDomain = show;
  void detachDomains(void Function(String domain) show) {
    if (_showDomain == show) _showDomain = null;
  }

  /// 这一页要不要显示。
  bool visibleOn(String? book, String? title) =>
      _ready &&
      book != null &&
      book == bookId &&
      checkBoardPages.containsKey(title) &&
      !_dismissed.contains(book) &&
      (pendingTotal > 0 || _finished);

  bool get onChecks => page == '检查与修复';
  int get pendingTotal => tracks.fold(0, (n, t) => n + t.pending);
  int get doneTotal => tracks.fold(0, (n, t) => n + t.done);
  bool get finished => _finished && pendingTotal == 0;

  /// 某一段还没处理的数量；这一段没有问题时为 0。
  int pendingOf(String domain) =>
      tracks.where((t) => t.id == domain).firstOrNull?.pending ?? 0;

  CheckTrack? trackOf(String id) => tracks.where((t) => t.id == id).firstOrNull;

  /// 页面打开或换页时调用。这里绝不跑全书检查：没检查过的书什么都不显示。
  void enter(String? book, String? title) {
    final changedPage = title != page;
    page = title;
    if (changedPage) {
      _finished = false;
      // 到了别的页面，还站在上一页的问题上就不对了：等用户点下一条。
      final home = checkBoardPages[title];
      if (home != null && selected != null && selected!.track != home) {
        selected = null;
      }
    }
    if (book == null || !checkBoardPages.containsKey(title)) {
      if (changedPage) notifyListeners();
      return;
    }
    if (book != bookId) {
      _bind(book);
    } else if (changedPage) {
      notifyListeners();
    }
    if (_report == null || !_ready) {
      unawaited(_reload());
    } else {
      // 离开这些页面期间书稿可能变了。
      _changed();
    }
    if (title == '文本清理') unawaited(_ensureSpots());
  }

  void _bind(String book) {
    _checks?.changes.removeListener(_changed);
    _checks?.dispose();
    _ticket++;
    _refresh?.cancel();
    bookId = book;
    tracks = const [];
    selected = null;
    _ready = false;
    _finished = false;
    _failures = 0;
    _structure = null;
    _queue = Int32List(0);
    _queueGuard = null;
    _pages.clear();
    _spots = null;
    _spotsGuard = null;
    _draftRules = null;
    _draftKey = null;
    _draftTimer?.cancel();
    _open = Int32List(0);
    _metadata = const [];
    _resources = const [];
    _report = null;
    _checks = library.openChecks(book)..changes.addListener(_changed);
    _chapters = library.openChapters(book);
  }

  /// 用户手动检查完：从头算进度。
  Future<void> reload() async {
    _finished = false;
    _queueGuard = null;
    _spotsGuard = null;
    _dismissedRemove();
    await _reload();
  }

  void _dismissedRemove() {
    if (bookId case final book?) _dismissed.remove(book);
  }

  Future<void> _reload() async {
    final checks = _updates;
    if (checks == null) return;
    final report = checks.shown;
    _report = report;
    if (report == null) {
      _ready = false;
      tracks = const [];
      notifyListeners();
      return;
    }
    _takeReport(report);
    await _syncQueue();
    if (_disposed) return;
    _ready = true;
    _readDraft();
    if (_spots != null) {
      _filterSpots();
    } else {
      if (_draftKey != null) {
        unawaited(_ensureSpots());
      } else if (await checks.storedSpots() case final stored?) {
        // 重启后不用跑清理，保留过的行也能马上算进进度。
        if (_disposed || !identical(_updates, checks)) return;
        if (_spots == null && _draftKey == null) {
          _adopt(stored, _report?.guards['cleanup']);
        }
      }
    }
    _rebuild();
    _scheduleIfStale();
  }

  void _adopt(CheckSpots spots, String? guard) {
    _spots = spots;
    _spotsGuard = _spotsKey(guard);
    _filterSpots();
    if (_wantLine case final line?) {
      _wantLine = null;
      if (selected?.track == 'cleanup') {
        selected = (track: 'cleanup', index: _indexOfLine(line));
      }
    }
  }

  String? _spotsKey(String? guard) =>
      guard == null ? null : '$guard|$_draftKey';

  /// 从检查结果里取每一段的问题。没等章节队列读完之前，先用结果里的数量。
  void _takeReport(BookCheckReport report) {
    _report = report;
    CheckDomain? of(String id) =>
        report.domains.where((d) => d.id == id).firstOrNull;
    _readDraft(); // 采用方案后草稿和已保存的规则一样了。
    _metadata = _updates?.metadataFindings() ?? of('metadata')?.findings ?? [];
    _resources = of('resources')?.findings ?? const [];
    final guard = report.guards['cleanup'];
    if (guard == null || _spotsKey(guard) != _spotsGuard) {
      _spots = null;
      _spotsGuard = null;
      if (page == '文本清理' || selected?.track == 'cleanup') {
        unawaited(_ensureSpots());
      }
    }
    _rebuild();
  }

  void _rebuild() {
    final report = _report;
    if (report == null || _disposed) return;
    final before = pendingTotal;
    int base(String id, int pending) {
      // 规则还是草稿：这一批是新的，只有保留过的算做完。
      if (id == 'cleanup' && _draftKey != null && _spots != null) {
        return _spots!.length;
      }
      // 刚关掉一项书籍信息检查：不等后台，这一段马上按新的算。
      if (id == 'metadata' && _updates?.rulesCurrent(id) == false) {
        return pending;
      }
      return (report.baseline[id] ?? pending) > pending
          ? report.baseline[id]!
          : pending;
    }

    int countOf(String id) =>
        report.domains.where((d) => d.id == id).firstOrNull?.count ?? 0;
    final chapters = _queueGuard == null ? countOf('chapters') : _queue.length;
    final cleanup = _spots == null ? countOf('cleanup') : _open.length;
    tracks = [
      for (final (id, label, pending) in [
        ('chapters', '章节', chapters),
        ('cleanup', '文本', cleanup),
        ('metadata', '信息', _metadata.length),
        ('resources', '图片', _resources.length),
      ])
        if (base(id, pending) > 0)
          CheckTrack(id, label, base(id, pending), pending),
    ];
    if (before > 0 && pendingTotal == 0 && _ready) _finished = true;
    _clampSelection();
    final sum = Object.hashAll([
      for (final track in tracks) ...[track.id, track.total, track.pending],
    ]);
    if (sum != counts.value) counts.value = sum;
    notifyListeners();
  }

  void _clampSelection() {
    final cell = selected;
    if (cell == null) return;
    final pending = pendingOf(cell.track);
    if (pending == 0) {
      selected = (track: cell.track, index: -1);
    } else if (cell.index >= pending) {
      selected = (track: cell.track, index: pending - 1);
    }
  }

  /// 读章节问题的位置。结果没变时不读。
  Future<void> _syncQueue({bool force = false}) async {
    final chapters = _chapters, report = _report;
    if (chapters == null || report == null) return;
    final guard = report.guards['chapters'] ?? report.guard;
    if (!force && guard == _queueGuard) return;
    final ticket = ++_ticket;
    try {
      final tree = await chapters.read(0);
      final Int32List queue;
      if (chapters is ChapterIssueQueueSession) {
        queue = await (chapters as ChapterIssueQueueSession).issueQueue(tree);
      } else {
        final first = await chapters.issues(tree, 0, effective: true);
        queue = Int32List.fromList([for (var i = 0; i < first.total; i++) i]);
      }
      if (ticket != _ticket || _disposed) return;
      _structure = tree;
      _queue = queue;
      _queueGuard = guard;
      _pages.clear();
    } catch (_) {
      // 书稿刚变：等这次更新结束再读。
    }
  }

  /// 文本问题的位置要到用时才读。存过的直接读文件，没存过才跑一遍清理。
  Future<void> _ensureSpots() async {
    final checks = _updates;
    if (checks == null || _spotsLoading || _report == null) return;
    _readDraft();
    final guard = _report?.guards['cleanup'];
    if (_spots != null && guard != null && _spotsKey(guard) == _spotsGuard) {
      return;
    }
    final key = _draftKey;
    _spotsLoading = true;
    try {
      final spots = await checks.spots(pipeline: _draftRules);
      if (_disposed || !identical(_checks, checks)) return;
      if (key == _draftKey) {
        _adopt(spots, guard);
        _rebuild();
      }
    } catch (_) {
      // 读不出来就先按结果里的数量显示。
    } finally {
      _spotsLoading = false;
    }
    // 读的时候规则又改了：按新的再读一次。
    if (key != _draftKey && !_disposed) unawaited(_ensureSpots());
  }

  /// 去掉用户已经决定保留的那些处。
  void _filterSpots() {
    final spots = _spots;
    if (spots == null) return;
    final kept = _kept;
    final open = Int32List(spots.length);
    var count = 0;
    for (var i = 0; i < spots.length; i++) {
      if (kept.isEmpty || !kept.contains(spots.pageLineAt(i))) {
        open[count++] = i;
      }
    }
    _open = Int32List.sublistView(open, 0, count);
  }

  /// 保留原文或删除候选的行：清理页的草稿，加上已采用的方案。
  Set<int> _kept = const {};

  /// 读清理页的草稿，看规则变没变、哪些行决定保留。
  void _readDraft() {
    final store = library;
    final checks = _updates;
    if (checks == null) return;
    final kept = <int>{...checks.keptCleanupLines()};
    List<Map<String, dynamic>>? rules;
    if (store is WorkspaceAutosaveService) {
      final raw = (store as WorkspaceAutosaveService).readDraft(
        'cleanup:$bookId',
      )?['rules'];
      if (raw is String) {
        try {
          final draft = jsonDecode(raw) as Map;
          kept
            ..addAll(((draft['skip_lines'] as List?) ?? const []).cast<int>())
            ..addAll(
              ((draft['remove_lines'] as List?) ?? const []).cast<int>(),
            );
          rules = (draft['pipeline'] as List?)
              ?.map((r) => (r as Map).cast<String, dynamic>())
              .toList();
        } catch (_) {
          // 草稿读不出来就按已保存的算。
        }
      }
    }
    _kept = kept;
    final key = rules == null ? null : cleanupPipelineKey(rules);
    final own = key == checks.cleanupRulesKey ? null : key;
    if (own != _draftKey) {
      _draftKey = own;
      _draftRules = own == null ? null : rules;
      _spots = null;
      _spotsGuard = null;
    }
  }

  /// 书稿或结果变了。书籍信息直接重算，其余等书稿停下来再更新。
  void _changed() {
    final checks = _updates;
    if (checks == null) return;
    final metadata = checks.metadataFindings();
    final report = checks.shown;
    if (report == null) {
      // 书被移除或工作区清空了。
      if (_report != null) {
        _report = null;
        _ready = false;
        tracks = const [];
        selected = null;
        notifyListeners();
      }
      return;
    }
    final fresh = !identical(report, _report);
    final metadataChanged = !_sameFindings(metadata, _metadata);
    if (fresh) {
      _takeReport(report);
      unawaited(_afterReport());
    } else if (metadataChanged) {
      _metadata = metadata;
      _rebuild();
    }
    _scheduleIfStale();
  }

  Future<void> _afterReport() async {
    await _syncQueue();
    if (_disposed) return;
    _ready = _ready || _report != null;
    _rebuild();
  }

  static bool _sameFindings(List<CheckFinding> a, List<CheckFinding> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _scheduleIfStale() {
    final checks = _checks, report = _report;
    if (checks == null || report == null || checks.isCurrent(report)) {
      _failures = 0;
      return;
    }
    if (!checkBoardPages.containsKey(page) || _failures >= 3) return;
    _refresh?.cancel();
    _refresh = Timer(refreshDelay, _update);
  }

  Future<void> _update() async {
    final checks = _updates;
    if (checks == null) return;
    if (_updateRunning) {
      _updateAgain = true;
      return;
    }
    _updateRunning = true;
    updating = true;
    notifyListeners();
    try {
      final report = await checks.update();
      if (_disposed || !identical(_updates, checks)) return;
      _failures = 0;
      _takeReport(report);
      await _syncQueue();
    } catch (_) {
      _failures++;
    } finally {
      _updateRunning = false;
      updating = false;
      if (!_disposed) {
        _rebuild();
        if (_updateAgain) {
          _updateAgain = false;
          _scheduleIfStale();
        }
      }
    }
  }

  /// 页面上下了结论或改了书稿之后调用。
  Future<void> issuesChanged() async {
    await _syncQueue(force: true);
    if (!_disposed) _rebuild();
  }

  /// 清理页的草稿变了：改了规则就按新规则重算位置，只改了保留的行就重新数。
  void cleanupChanged() {
    final key = _draftKey;
    _readDraft();
    if (key != _draftKey) {
      _draftTimer?.cancel();
      _draftTimer = Timer(refreshDelay, () => unawaited(_ensureSpots()));
      _rebuild();
      return;
    }
    if (_spots == null) return;
    _filterSpots();
    _rebuild();
  }

  /// 清理页点选了一处：进度条跟上。不是全部处理的那一处（已保留的）就不动。
  void noteLine(int line, int end) {
    final spots = _spots;
    if (spots == null) return;
    for (var i = 0; i < _open.length; i++) {
      final at = spots.pageLineAt(_open[i]);
      if (at < line || at > end) continue;
      if (selected?.track == 'cleanup' && selected?.index == i) return;
      selected = (track: 'cleanup', index: i);
      notifyListeners();
      return;
    }
  }

  // ---------------------------------------------------------------- 走动

  /// 这一段接下来有问题的段；没有时为空。
  CheckTrack? _neighbour(String id, int delta) {
    var at = tracks.indexWhere((t) => t.id == id) + delta;
    while (at >= 0 && at < tracks.length) {
      if (tracks[at].pending > 0) return tracks[at];
      at += delta;
    }
    return null;
  }

  /// 这一段走到头时可以去的下一段。
  CheckTrack? get nextTrack {
    final cell = selected;
    if (cell == null) return null;
    final pending = pendingOf(cell.track);
    if (cell.index < pending - 1) return null;
    return _neighbour(cell.track, 1);
  }

  bool canStep(int delta) {
    final cell = selected;
    if (cell == null) return pendingTotal > 0;
    final next = cell.index + delta;
    return next >= 0 && next < pendingOf(cell.track);
  }

  /// 上一条、下一条：只在这一段里走。走到头再按一次才换段，不会突然跳到别的页面。
  void step(int delta) {
    final cell = selected;
    if (cell == null) {
      final home = checkBoardPages[page];
      final track =
          tracks.where((t) => t.id == home && t.pending > 0).firstOrNull ??
          tracks.where((t) => t.pending > 0).firstOrNull;
      if (track != null) select(track.id, 0);
      return;
    }
    final next = cell.index + delta;
    if (next >= 0 && next < pendingOf(cell.track)) {
      select(cell.track, next);
      return;
    }
    final other = _neighbour(cell.track, delta);
    if (other != null) select(other.id, delta > 0 ? 0 : other.pending - 1);
  }

  /// 走到某一条：页面在就地显示，不在就过去。检查页上只切页签，不离开。
  void select(String track, int index) {
    if (index < 0 || index >= pendingOf(track)) return;
    selected = (track: track, index: index);
    notifyListeners();
    if (track == 'cleanup' && _spots == null) {
      // 位置还没读：读完再过去，这段时间用户又点了别处就不去了。
      unawaited(
        _ensureSpots().then((_) {
          if (selected?.track == track &&
              selected?.index == index &&
              !onChecks) {
            unawaited(_reveal(track, index));
          }
        }),
      );
      return;
    }
    if (onChecks) {
      _showDomain?.call(track);
      if (track == 'chapters') unawaited(_revealIssue(index));
      return;
    }
    unawaited(_reveal(track, index));
  }

  /// 检查页换了页签：进度条站到这一段的第一条，不跳转。
  void focusTrack(String track) {
    if (pendingOf(track) == 0 || selected?.track == track) return;
    selected = (track: track, index: 0);
    if (track == 'cleanup') unawaited(_ensureSpots());
    notifyListeners();
  }

  /// 从检查页去处理当前这一条。
  void handleSelected() {
    final cell = selected;
    if (cell == null || cell.index < 0) {
      step(1);
      return;
    }
    unawaited(_reveal(cell.track, cell.index));
  }

  Future<void> _revealIssue(int index) async {
    final issue = await issueAt(index);
    if (issue == null || index >= _queue.length) return;
    _showIssue?.call(issue.id, _queue[index]);
  }

  Future<void> _reveal(String track, int index) async {
    final book = bookId;
    if (book == null) return;
    String at(String name, [Map<String, String> query = const {}]) =>
        bookPageLocation(book, name, origin: location(), query: query);
    switch (track) {
      case 'chapters':
        final issue = await issueAt(index);
        if (issue == null || index >= _queue.length) return;
        final offset = _queue[index];
        if (page == '章节编辑' && _showIssue != null) {
          _showIssue!(issue.id, offset);
        } else {
          showChapterIssue(book, issue.id, offset);
        }
      case 'cleanup':
        final line = pageLineAt(index);
        if (line == null) return;
        if (page == '文本清理' && _showLine != null && _showLine!(line)) return;
        go(at('cleanup', {'focus': '$line'}));
      case 'metadata':
        final finding = _metadata[index];
        final field = finding.id.split(':').last;
        if (page == '书籍信息' && _showField != null) {
          _showField!(field);
        } else {
          go(at('information', {'focus': field}));
        }
      default:
        final finding = _resources[index];
        if (page == '图片与资源' && _showResource != null) {
          _showResource!(finding.id);
        } else {
          go(at('resources', {'focus': finding.id}));
        }
    }
  }

  /// 第 [index] 条章节问题的内容；不在手边时按页读。
  Future<ChapterIssue?> issueAt(int index) async {
    if (index < 0 || index >= _queue.length) return null;
    final offset = _queue[index];
    final start = offset ~/ 50 * 50;
    final page = _pages[start] ?? await _readPage(start);
    if (page == null) return null;
    final local = offset - page.offset;
    return local >= 0 && local < page.items.length ? page.items[local] : null;
  }

  ChapterIssue? _cachedIssue(int index) {
    if (index < 0 || index >= _queue.length) return null;
    final offset = _queue[index];
    final page = _pages[offset ~/ 50 * 50];
    if (page == null) return null;
    final local = offset - page.offset;
    return local >= 0 && local < page.items.length ? page.items[local] : null;
  }

  Future<ChapterIssuePage?> _readPage(int start) =>
      _loading[start] ??= () async {
        try {
          final chapters = _chapters;
          var tree = _structure;
          if (chapters == null) return null;
          tree ??= await chapters.read(0);
          final page = await chapters.issues(tree, start, effective: true);
          _pages.remove(start);
          _pages[start] = page;
          while (_pages.length > _keptPages) {
            _pages.remove(_pages.keys.first);
          }
          if (!_disposed) notifyListeners();
          return page;
        } catch (_) {
          return null;
        } finally {
          _loading.remove(start);
        }
      }();

  /// 第 [index] 处文本问题在清理页的行号。
  int? pageLineAt(int index) {
    final spots = _spots;
    if (spots == null || index < 0 || index >= _open.length) return null;
    return spots.pageLineAt(_open[index]);
  }

  String _ruleAt(int index) {
    final spots = _spots;
    if (spots == null) return '文本清理';
    final at = _open[index];
    if (spots.candidateAt(at)) return '广告候选';
    final rule = spots.rules[spots.steps[at]];
    return cleanupLabels[rule] ?? rule;
  }

  /// 进度条右边写的：当前问题和它的位置。
  (String, String) get current {
    if (pendingTotal == 0) return ('全部处理完了', '$doneTotal 处');
    final cell = selected;
    if (cell == null) return ('还有 $pendingTotal 个问题待处理', '');
    final track = trackOf(cell.track);
    if (track == null || cell.index < 0) {
      return ('${track?.label ?? ''}问题已全部处理', '');
    }
    return describe(cell.track, cell.index);
  }

  /// 某一格是什么。章节问题的内容不在手边时先写位置，同时去读。
  (String, String) describe(String track, int index) {
    switch (track) {
      case 'chapters':
        final issue = _cachedIssue(index);
        if (issue == null) {
          unawaited(issueAt(index));
          return ('第 ${index + 1} 条章节问题', '');
        }
        final line =
            issue.focusLine ?? (issue.lines.isEmpty ? null : issue.lines.first);
        return (issue.title, line == null ? '' : '第 $line 行');
      case 'cleanup':
        final line = pageLineAt(index);
        if (line == null) {
          unawaited(_ensureSpots());
          return ('第 ${index + 1} 处文本问题', '');
        }
        return (_ruleAt(index), '第 ${index + 1}/${_open.length} 处 · 第 $line 行');
      case 'metadata':
        return index < _metadata.length
            ? (_metadata[index].title, '书籍信息')
            : ('', '');
      default:
        return index < _resources.length
            ? (_resources[index].title, '图片资源')
            : ('', '');
    }
  }

  /// 主按钮上的字；这一条不需要按钮时为空。
  String? get action {
    final cell = selected;
    if (cell == null || cell.index < 0) return null;
    // 章节问题在检查页上有自己的“去处理”。
    if (onChecks) return cell.track == 'chapters' ? null : '去处理';
    if (checkBoardPages[page] != cell.track) return null;
    return switch (cell.track) {
      'chapters' => '核对无误',
      'cleanup' => _keepLine == null ? null : '保留原文',
      _ => null,
    };
  }

  /// 主按钮：下结论，这一条从队列里拿掉，停在原位，也就是下一条。
  Future<void> act() async {
    final cell = selected;
    if (cell == null || cell.index < 0) return;
    if (onChecks) return handleSelected();
    if (cell.track == 'chapters') {
      await _confirmIssue(cell.index);
    } else if (cell.track == 'cleanup') {
      final line = pageLineAt(cell.index);
      if (line == null || _keepLine == null || !_keepLine!(line)) return;
      _open = _without(_open, cell.index);
      _rebuild();
      final now = selected;
      if (now != null && now.index >= 0) select(now.track, now.index);
    }
  }

  Future<void> _confirmIssue(int index) async {
    final issue = await issueAt(index);
    final offset = index < _queue.length ? _queue[index] : -1;
    final page = _pages[offset ~/ 50 * 50];
    final chapters = _chapters;
    if (issue == null || page == null || chapters == null) return;
    try {
      final next = await chapters.reviewIssue(
        page,
        issue.id,
        'confirmed_normal',
      );
      _pages[next.offset] = next;
    } on FormatException {
      await issuesChanged();
      return;
    }
    _queue = _without(_queue, index);
    _rebuild();
    final now = selected;
    if (now != null && now.index >= 0) select(now.track, now.index);
    _pagesChanged?.call();
  }

  VoidCallback? _pagesChanged;

  /// 结论写进去之后，章节页要重读问题（批注、目录标记、页签数字都来自它）。
  void attachReviewListener(VoidCallback changed) => _pagesChanged = changed;
  void detachReviewListener(VoidCallback changed) {
    if (_pagesChanged == changed) _pagesChanged = null;
  }

  static Int32List _without(Int32List list, int index) {
    final next = Int32List(list.length - 1);
    next.setRange(0, index, list);
    next.setRange(index, next.length, list, index + 1);
    return next;
  }

  /// 问题页签里选中了一条：进度条跟上。
  void noteIssue(int offset) {
    var low = 0, high = _queue.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_queue[middle] < offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low >= _queue.length || _queue[low] != offset) {
      // 选中的是已经下过结论的：不在待处理里，进度条不能还写着别的问题。
      if (selected?.track == 'chapters') {
        selected = null;
        notifyListeners();
      }
      return;
    }
    if (selected?.track == 'chapters' && selected?.index == low) return;
    selected = (track: 'chapters', index: low);
    notifyListeners();
  }

  /// 检查页的文本列表点选了一行（有效稿行号）。
  void noteCheckLine(int line) {
    final spots = _spots;
    if (spots == null) return;
    for (var i = 0; i < _open.length; i++) {
      if (spots.lines[_open[i]] != line) continue;
      if (selected?.track != 'cleanup' || selected?.index != i) {
        selected = (track: 'cleanup', index: i);
        notifyListeners();
      }
      return;
    }
  }

  /// 当前这一处的有效稿行号；不在文本问题上时为空。
  int? get selectedCheckLine {
    final cell = selected, spots = _spots;
    if (cell?.track != 'cleanup' || spots == null) return null;
    final index = cell!.index;
    return index >= 0 && index < _open.length
        ? spots.lines[_open[index]]
        : null;
  }

  /// 当前这一处在报告里的序号，检查页按它翻页。
  int? get selectedCheckRow {
    final cell = selected, spots = _spots;
    if (cell?.track != 'cleanup' || spots == null) return null;
    final index = cell!.index;
    return index >= 0 && index < _open.length ? spots.rows[_open[index]] : null;
  }

  /// 当前这条信息或图片问题的编号。
  String? get selectedFindingId {
    final cell = selected;
    if (cell == null || cell.index < 0) return null;
    final list = switch (cell.track) {
      'metadata' => _metadata,
      'resources' => _resources,
      _ => const <CheckFinding>[],
    };
    return cell.index < list.length ? list[cell.index].id : null;
  }

  /// 检查页点选了一条信息或图片问题。
  void noteFinding(String id) {
    for (final (track, list) in [
      ('metadata', _metadata),
      ('resources', _resources),
    ]) {
      final index = list.indexWhere((f) => f.id == id);
      if (index >= 0) {
        if (selected?.track != track || selected?.index != index) {
          selected = (track: track, index: index);
          notifyListeners();
        }
        return;
      }
    }
  }

  /// 图片页选中了一行：这一行有问题时进度条跟上。
  void noteResource(int index) {
    final at = _resources.indexWhere(
      (f) => f.id.split(':').elementAtOrNull(1) == '$index',
    );
    if (at < 0 || (selected?.track == 'resources' && selected?.index == at)) {
      return;
    }
    selected = (track: 'resources', index: at);
    notifyListeners();
  }

  /// 书籍信息页标出了这个字段：进度条跟上。
  void noteField(String field) {
    final index = _metadata.indexWhere((f) => f.id.split(':').last == field);
    if (index < 0 || selected?.index == index) return;
    selected = (track: 'metadata', index: index);
    notifyListeners();
  }

  void backToChecks() {
    if (bookId case final book?) showChecks(book, selected?.track);
  }

  void close() {
    if (bookId case final book?) _dismissed.add(book);
    notifyListeners();
  }

  /// F8：关掉过的叫回来，已经显示的走下一条。
  void reopenOrStep(String book, int delta) {
    if (book != bookId) {
      enter(book, page);
    }
    if (_dismissed.remove(book)) {
      notifyListeners();
      return;
    }
    step(delta);
  }

  /// 从检查页点“去处理”：记下这一条，页面由调用方打开。
  void start(String book, {String? track, int? offset, int? line}) {
    _dismissed.remove(book);
    if (track == 'chapters' && offset != null) noteIssue(offset);
    if (track != null && track != 'chapters') {
      if (track == 'cleanup' && _spots == null) _wantLine = line;
      final index = line == null ? 0 : _indexOfLine(line);
      if (pendingOf(track) > 0) selected = (track: track, index: index);
    }
    notifyListeners();
  }

  /// 第一处不早于这一行的位置。修改过的书原稿行号不一定递增，所以逐个看；
  /// 十万个整数也用不到一毫秒。
  int _indexOfLine(int line) {
    final spots = _spots;
    if (spots == null) return 0;
    for (var i = 0; i < _open.length; i++) {
      if (spots.pageLineAt(_open[i]) >= line) return i;
    }
    return 0;
  }

  @override
  void dispose() {
    _disposed = true;
    _ticket++;
    _refresh?.cancel();
    _draftTimer?.cancel();
    _checks?.changes.removeListener(_changed);
    _checks?.dispose();
    counts.dispose();
    super.dispose();
  }
}

/// 让页面找到进度条。没有这一层（单页测试）时页面照常工作。
class CheckBoardScope extends InheritedWidget {
  const CheckBoardScope({super.key, required this.board, required super.child});
  final CheckBoard board;
  static CheckBoard? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CheckBoardScope>()?.board;
  @override
  bool updateShouldNotify(CheckBoardScope oldWidget) =>
      board != oldWidget.board;
}
