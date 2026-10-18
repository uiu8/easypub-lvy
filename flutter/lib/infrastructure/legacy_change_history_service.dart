import 'dart:convert';

import 'legacy_rule_catalog_service.dart';

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../src/rust/api.dart' as api;

import 'package:flutter/foundation.dart';

import '../application/change_history_service.dart';
import '../application/book_information_service.dart';
import '../application/layout_service.dart';
import '../prototype/prototype_state.dart';

class LegacyChangeHistoryService
    implements ChangeHistoryService, RedoChangeHistoryService {
  LegacyChangeHistoryService(this.backend) {
    _loadTimes();
    _stampAll(initial: true);
    // 只占用一个监听：清记录缓存与登记变更时间在同一回调里完成。
    backend.addListener(_onBackendChanged);
  }

  void _onBackendChanged() {
    _invalidateRecords();
    _observeTimes();
  }

  final PrototypeState backend;
  final _recordsCache = <String, List<ChangeRecord>>{};
  void _invalidateRecords() => _recordsCache.clear();
  void dispose() {
    backend.removeListener(_onBackendChanged);
    _recordsCache.clear();
  }

  // ---------------------------------------------------------------- 变更时间登记
  // 历史快照本身不带时间。这里在每个版本首次成为当前版本时记下时间（按快照内容摘要），
  // 保存在设置目录 change-times.json；登记开始前已有的版本记为空串，界面显示“时间未记录”。
  final _times = <String, Map<String, Map<String, String>>>{};
  final _lastSignature = <String, String>{};
  final _knownBooks = <String>{};
  File? get _timesFile => backend.settingsDirectory == null
      ? null
      : File('${backend.settingsDirectory}/change-times.json');

  /// 工作区被整体替换（打开项目、清空）后调用：新载入的历史一律视为已有版本。
  void resetTimeObservation() {
    _knownBooks.clear();
    _lastSignature.clear();
    _stampAll(initial: true);
  }

  void _loadTimes() {
    try {
      final file = _timesFile;
      if (file == null || !file.existsSync()) return;
      final raw = jsonDecode(file.readAsStringSync()) as Map;
      for (final book in raw.entries) {
        _times[book.key as String] = {
          for (final domain in (book.value as Map).entries)
            domain.key as String: (domain.value as Map).map(
              (k, v) => MapEntry(k as String, v as String),
            ),
        };
      }
    } on Object {
      _times.clear();
    }
  }

  void _saveTimes() {
    try {
      final file = _timesFile;
      if (file == null) return;
      file.parent.createSync(recursive: true);
      final temp = File('${file.path}.tmp')
        ..writeAsStringSync(jsonEncode(_times));
      temp.renameSync(file.path);
    } on Object {
      // 时间只用于显示分组；写入失败不影响编辑与历史本身。
    }
  }

  static String _digest(Object? state) =>
      sha1.convert(utf8.encode(jsonEncode(state))).toString().substring(0, 20);

  /// 工作区整体替换期间暂停登记，替换完成后由 [resetTimeObservation] 重新建立基线。
  bool observing = true;

  void _observeTimes() {
    if (!observing || backend.taskNotification) return;
    _stampAll(initial: false);
  }

  /// 只给“新追加并成为当前”的最新版本记时间；撤销、重做不产生新时间。
  /// 启动时各历史的最新版本若尚无记录，记为“时间未记录”。
  void _stampAll({required bool initial}) {
    var changed = false;
    final now = DateTime.now().toIso8601String();
    for (final book in backend.shelf.books) {
      final id = book.id;
      // 第一次见到的书（启动、导入、打开项目）：已有历史都按“时间未记录”处理。
      final existing = _knownBooks.add(id) || initial;
      for (final entry in histories(id).entries) {
        final history = entry.value;
        if (history == null) continue;
        final raw = (history['states'] ?? history['history']) as List?;
        if (raw == null || raw.isEmpty) continue;
        final cursor = history['cursor'] as int? ?? raw.length - 1;
        final key = '$id/${entry.key}';
        final signature = '${raw.length}:$cursor';
        if (_lastSignature[key] == signature) continue;
        _lastSignature[key] = signature;
        if (!existing && cursor != raw.length - 1) continue;
        final domain = _times
            .putIfAbsent(id, () => {})
            .putIfAbsent(entry.key, () => {});
        final latest = _digest(states(history).last);
        if (!domain.containsKey(latest)) {
          domain[latest] = existing ? '' : now;
          changed = true;
        }
      }
    }
    if (changed) _saveTimes();
  }

  DateTime? _timeOf(String bookId, String domain, Object? state) {
    final value = _times[bookId]?[domain]?[_digest(state)];
    return value == null || value.isEmpty ? null : DateTime.tryParse(value);
  }

  @override
  Listenable get changes => backend;
  final issued = Expando<String>();
  Map<String, Map<String, dynamic>?> histories(String id) => {
    '章节': backend.manuscript.effectiveHistories[id],
    '人工编辑': backend.manuscript.manualEditDrafts[id],
    '结构': backend.manuscript.structureHistories[id],
    '文本清理': backend.cleanup.histories[id],
    '制作': backend.production.histories[id],
    '规则开关': backend.production.drafts[id]?.ruleToggleHistory,
  };
  List<dynamic> states(Map<String, dynamic> history) =>
      ((history['states'] ?? history['history']) as List)
          .map((value) {
            if (value is Map && value['recorded_request'] != null) {
              return Map<String, dynamic>.from(value)
                ..['request'] = value['recorded_request']
                ..remove('recorded_request');
            }
            return value;
          })
          .toList(growable: false);
  static const labels = {
    ...bookInformationFields,
    'cover_path': '封面文件',
    'cover_crop': '封面裁剪',
    'cover_fit': '封面适配',
    'cover_design': '封面设计',
    'font_size': '字号',
    'line_height': '行距',
    'font_family': '字体',
    'paragraph_indent': '首行缩进',
    'paragraph_spacing': '段间距',
    'additional_css': '附加 CSS',
    'margins': '页边距',
    'include_toc': '收录目录',
    'visible_toc': '书内目录页',
    'chapter_navigation': '章节导航',
    'text_alignment': '对齐方式',
    'writing_mode': '书写方向',
    'vertical_digits': '竖排数字横排',
    'heading_style': '章节标题样式',
    'scene_break_style': '场景分隔',
    'note_style': '弹出式注释',
    'first_paragraph_style': '章首段落',
    'rare_char_ruby': '生僻字注音',
    'rare_char_scope': '生僻字范围',
    'chapter_head_image': '章首图',
    'chapter_style': '章节样式包',
    'chapter_head_scope': '章首图用于',
    'chapter_head_width': '章首图宽度',
    'system_block_style': '系统提示',
    'verse_block_style': '诗词',
    'block_annotations': '手工标注块',
    'manual_notes': '手工注释',
    'supplemental_pages': '前后附页',
    'actions': '操作',
    'request': '编辑方案',
    'base': '依据版本',
    'kind': '操作类型',
    'recognition_rules': '识别规则',
    'rule_version': '规则版本',
    'rule_fingerprint': '规则指纹',
    'chapter_pattern': '常规标题表达式',
    'preserve_decisions': '沿用已确认位置',
    'version': '版本',
    'origin': '来源',
    'hierarchy': '按卷章节识别',
    'volume_pattern': '卷标题表达式',
    'level_chapter_pattern': '章标题表达式',
    'section_pattern': '节标题表达式',
    'numeric': '数字标题识别',
    'numeric_pattern': '数字标题表达式',
    'numeric_minimum_body_lines': '数字标题最小正文行数',
    'normalize_numeric_titles': '规范数字标题',
    'number_corrections': '编号错字表',
    'entry_id': '节点',
    'first_offset': '正文起始行',
    'last_offset': '正文结束行',
    'source_line': '原稿行号',
    'before_line': '目标原稿行',
    'end_line': '结束行',
    'volume_title': '卷标题',
    'overrides': '结构调整',
    'entry_ids': '节点列表',
    'parent_id': '父节点',
    'depth': '层级',
    'role': '类型',
    'rules': '规则',
    'pattern': '匹配文本',
    'replacement': '替换文本',
    'enabled': '启用',
  };
  String summary(Object? value) {
    if (value == null) return '未设置';
    if (value is bool) return value ? '开启' : '关闭';
    if (value is List) return '${value.length} 项';
    if (value is Map) return '${value.length} 个字段';
    final text =
        const {
          'factory': '内置默认',
          'builtin': '内置规则',
          'import_default': '导入默认快照',
          'preset': '规则预设',
          'book': '本书设置',
          'global': '全局设置',
          'rename': '重命名',
          'recognize': '重新识别章节',
          'rename_title': '修改标题',
          'repair_number_typo': '修正编号',
          'move_chapter': '移动章节',
          'move_volume': '移动卷',
          'exclude_lines': '排除原稿行',
          'split_chapter': '拆分章节',
          'set_volume': '设置卷标题',
          'move': '移动',
          'classify': '调整类型',
          'exclude_body_lines': '删除正文行',
          'remove': '移除',
          'include': '收录',
        }[value.toString()] ??
        value.toString();
    return text.length > 200 ? '${text.substring(0, 200)}…（节选）' : text;
  }

  String metadataSource(Object? raw) {
    final origin = raw is Map ? raw : const {};
    return switch (origin['source']) {
      'manual' => '手工确认',
      'folder_rule' => origin['rule_priority'] == 1 ? '项目目录规则' : '全局目录规则',
      'imported' => '导入信息',
      'conversion' => '本次转换',
      _ => '来源未知',
    };
  }

  String metadataValue(Object? value) => value == '' ? '已清空' : summary(value);

  @override
  List<ChangeRecord> records(String bookId) {
    final cached = _recordsCache[bookId];
    if (cached != null) return cached;
    if (!backend.shelf.books.any((b) => b.id == bookId && !b.isDemo)) {
      return const [];
    }
    final result = <ChangeRecord>[];
    final guard = backend.publicationContext(bookId);
    for (final entry in histories(bookId).entries) {
      final h = entry.value;
      if (h == null) continue;
      final list = states(h), cursor = h['cursor'] as int;
      for (var i = list.length - 1; i > 0; i--) {
        final domain = entry.key;
        if (domain == '章节' || domain == '制作') {
          final combined = backend.production.drafts[bookId]?.ruleToggleHistory;
          final key = domain == '章节'
              ? 'effective_history'
              : 'production_history';
          if ((combined?['states'] as List? ?? []).skip(1).cast<Map>().any((s) {
            final h = (s['after'] as Map)[key] as Map?;
            return h != null &&
                h['cursor'] == i &&
                jsonEncode((h['states'] ?? h['history'])[i]) ==
                    jsonEncode(list[i]);
          })) {
            continue;
          }
        }
        var category = domain;
        if (domain == '制作') {
          final a = list[i - 1] as Map, b = list[i] as Map;
          final changed = {...a.keys, ...b.keys}
              .where(
                (key) =>
                    jsonEncode(a[key]) != jsonEncode(b[key]) &&
                    key != 'layout_origins' &&
                    key != 'metadata_origins',
              )
              .toSet();
          // Origin-only confirmation still belongs to the affected field.
          for (final container in ['layout_origins', 'metadata_origins']) {
            final old = a[container] is Map ? a[container] as Map : const {};
            final next = b[container] is Map ? b[container] as Map : const {};
            changed.addAll(
              {...old.keys, ...next.keys}.where(
                (field) => jsonEncode(old[field]) != jsonEncode(next[field]),
              ),
            );
          }
          category =
              changed.length == 1 && changed.contains('supplemental_pages')
              ? '前后附页'
              : changed.length == 1 && changed.contains('manual_notes')
              ? '手工注释'
              : changed.length == 1 && changed.contains('block_annotations')
              ? '手工标注'
              : changed.isNotEmpty && changed.every(layoutFields.contains)
              ? '排版'
              : changed.isNotEmpty &&
                    changed.every(
                      (key) =>
                          bookInformationFields.containsKey(key) ||
                          key.toString().startsWith('cover_') ||
                          key == 'language',
                    )
              ? '书籍信息'
              : '批量制作';
        }
        final snapshot = list[i];
        final chapterActions = snapshot is Map && snapshot['request'] is Map
            ? snapshot['request']['actions'] as List? ?? const []
            : const [];
        final recognition =
            domain == '章节' &&
            chapterActions.isNotEmpty &&
            chapterActions.last is Map &&
            chapterActions.last['kind'] == 'recognize';
        final record = ChangeRecord(
          '$bookId/$domain/$i',
          bookId,
          domain,
          domain == '规则开关'
              ? '规则开关'
              : recognition
              ? '重新识别章节'
              : '修改$category',
          i,
          i <= cursor,
          i == cursor,
          domain == '制作'
              ? (category == '手工标注' || category == '手工注释')
                    ? 'chapters'
                    : category == '排版'
                    ? 'layout'
                    : 'information'
              : domain == '文本清理'
              ? 'cleanup'
              : 'chapters',
          category: category,
          canRedo: i == cursor + 1,
          time: _timeOf(bookId, domain, list[i]),
        );
        issued[record] = guard;
        result.add(record);
      }
    }
    final frozen = List<ChangeRecord>.unmodifiable(result);
    _recordsCache[bookId] = frozen;
    return frozen;
  }

  void check(ChangeRecord record, String guard) {
    if (issued[record] != guard ||
        backend.publicationContext(record.bookId) != guard) {
      throw const FormatException('书稿已变化，请重新选择记录。');
    }
  }

  @override
  ChangeDetail detail(ChangeRecord record) {
    final guard = issued[record];
    if (guard == null) throw const FormatException('请从当前记录列表选择。');
    check(record, guard);
    final h = histories(record.bookId)[record.domain]!;
    final list = states(h);
    final fields = <ChangedField>[];
    void compare(Object? before, Object? after, String path, int depth) {
      if (jsonEncode(before) == jsonEncode(after)) return;
      if (fields.length >= 80) return;
      if (depth < 5 && (before is Map || after is Map)) {
        final a = before is Map ? before : const {},
            b = after is Map ? after : const {};
        for (final key in {...a.keys, ...b.keys}) {
          if (key == 'metadata_origins') {
            final old = a[key] is Map ? a[key] as Map : const {};
            final next = b[key] is Map ? b[key] as Map : const {};
            for (final field in {...old.keys, ...next.keys}) {
              final x = old[field] is Map ? old[field] as Map : const {};
              final y = next[field] is Map ? next[field] as Map : const {};
              if (jsonEncode(x) == jsonEncode(y)) continue;
              final name = labels[field] ?? field.toString();
              void add(String suffix, String before, String after) {
                if (before != after && fields.length < 80) {
                  fields.add(ChangedField('$name$suffix', before, after));
                }
              }

              add('来源', metadataSource(x), metadataSource(y));
              add(
                '关联目录',
                metadataValue(x['rule_folder']),
                metadataValue(y['rule_folder']),
              );
              if (x['rule_version'] != y['rule_version'] &&
                  x['rule_version'] != null &&
                  y['rule_version'] != null) {
                add('规则版本', '原规则版本', '更新后的规则版本');
              }
              final xb = x['baseline'] is Map ? x['baseline'] as Map : const {};
              final yb = y['baseline'] is Map ? y['baseline'] as Map : const {};
              String baseline(Map value) => value.isEmpty
                  ? '无恢复基础'
                  : '${metadataSource(value)} · ${metadataValue(value['value'])}';
              add('可恢复基础', baseline(xb), baseline(yb));
            }
            continue;
          }
          if (key == 'layout_origins') {
            final originsBefore = a[key] is Map ? a[key] as Map : const {};
            final originsAfter = b[key] is Map ? b[key] as Map : const {};
            for (final field in {...originsBefore.keys, ...originsAfter.keys}) {
              final old = originsBefore[field] is Map
                  ? originsBefore[field]['source']
                  : null;
              final next = originsAfter[field] is Map
                  ? originsAfter[field]['source']
                  : null;
              if (old != next && fields.length < 80) {
                fields.add(
                  ChangedField(
                    '${labels[field] ?? field}设置来源',
                    summary(old),
                    summary(next),
                  ),
                );
              }
            }
            continue;
          }
          final name = key == 'title' && record.domain != '制作'
              ? '标题'
              : labels[key] ?? key.toString();
          compare(
            a[key],
            b[key],
            path.isEmpty ? name : '$path / $name',
            depth + 1,
          );
        }
      } else if (depth < 5 && (before is List || after is List)) {
        final a = before is List ? before : const [],
            b = after is List ? after : const [];
        final count = a.length > b.length ? a.length : b.length;
        for (var i = 0; i < count && fields.length < 80; i++) {
          compare(
            i < a.length ? a[i] : null,
            i < b.length ? b[i] : null,
            '$path ${i + 1}',
            depth + 1,
          );
        }
      } else {
        fields.add(
          ChangedField(
            path.isEmpty ? '方案' : path,
            summary(before),
            bookInformationFields.containsKey(path)
                ? metadataValue(after)
                : summary(after),
          ),
        );
      }
    }

    compare(list[record.version - 1], list[record.version], '', 0);
    return ChangeDetail(record, fields, guard);
  }

  @override
  Future<HistoryTrees> chapterTrees(
    ChangeDetail detail,
    int offset, {
    String? entryId,
  }) async {
    check(detail.record, detail.guard);
    if (detail.record.domain != '章节' || offset < 0) {
      throw const FormatException('该记录没有可重放的章节快照。');
    }
    final history = histories(detail.record.bookId)['章节']!;
    final frozen = jsonEncode(history);
    final sourceId = history['source_id'] as String;
    final revision = history['revision'] as int;
    final pages = <Map>[];
    for (final version in [detail.record.version - 1, detail.record.version]) {
      final raw = await api.editEffectiveDraft(
        sourceId: sourceId,
        revision: revision,
        baseJson: '',
        draftJson: frozen,
        commandJson: jsonEncode({
          'op': 'inspect_snapshot',
          'entry_id': ?entryId,
          'version': version,
          'offset': offset,
        }),
      );
      check(detail.record, detail.guard);
      pages.add(jsonDecode(raw) as Map);
    }
    List<HistoryTreeNode> nodes(Map page) => (page['nodes'] as List)
        .cast<Map>()
        .map(
          (n) => HistoryTreeNode(
            n['entry_id'] as String,
            n['title'] as String,
            n['depth'] as int,
            n['role'] as String,
          ),
        )
        .toList();
    return HistoryTrees(
      nodes(pages[0]),
      nodes(pages[1]),
      pages[0]['total'] as int,
      pages[1]['total'] as int,
      offset,
      beforeOffset: pages[0]['offset'] as int,
      afterOffset: pages[1]['offset'] as int,
      entryId: entryId,
      beforeFound: pages[0]['focus_found'] == true,
      afterFound: pages[1]['focus_found'] == true,
    );
  }

  @override
  Future<void> undo(ChangeDetail preview) => move(preview, undo: true);

  @override
  Future<void> redo(ChangeDetail preview) => move(preview, undo: false);

  Future<void> move(ChangeDetail preview, {required bool undo}) async {
    final record = preview.record;
    final command = {'op': undo ? 'undo' : 'redo'};
    check(record, preview.guard);
    final h = histories(record.bookId)[record.domain];
    if (h == null ||
        h['cursor'] != (undo ? record.version : record.version - 1) ||
        !(undo ? record.canUndo : record.canRedo) ||
        backend.projectBusy ||
        backend.importing ||
        backend.production.busy ||
        backend.queueActive ||
        backend.outputs.batchBusy) {
      throw const FormatException('当前不能恢复此记录；请先结束其他操作或重新选择当前一步。');
    }
    switch (record.domain) {
      case '规则开关':
        final service = LegacyRuleCatalogService(backend, record.bookId);
        try {
          await service.moveHistory(undo: undo);
        } finally {
          service.dispose();
        }
      case '制作':
        final plan = await backend.production.previewChanges({
          record.bookId: command,
        });
        check(record, preview.guard);
        if (!await backend.production.confirm(plan)) {
          throw const FormatException('记录已失效。');
        }
      case '文本清理':
        if (!await backend.cleanup.editSettings(record.bookId, command)) {
          throw FormatException(
            backend.cleanup.historyStatus[record.bookId] ?? '清理记录未能恢复。',
          );
        }
      case '章节':
        final source = backend.shelf.books
            .firstWhere((b) => b.id == record.bookId)
            .source!;
        final result = jsonDecode(
          await api.editEffectiveDraft(
            sourceId: source.sourceId,
            revision: source.revision,
            baseJson: jsonEncode(
              backend.manuscript.effectiveBase(record.bookId),
            ),
            draftJson: jsonEncode(h),
            commandJson: jsonEncode(command),
          ),
        ) as Map;
        check(record, preview.guard);
        // Native identity compares the composed manuscript, not optional JSON
        // defaults added by save/reopen. Never publish a mismatched cursor.
        if (result['matches_current'] != true) {
          throw const FormatException('章节依据已经改变，请先恢复对应清理、结构或人工编辑版本。');
        }
        backend.change(
          () => backend.manuscript.effectiveHistories[record.bookId] =
              (result['history'] as Map).cast<String, dynamic>(),
        );
      case '结构':
      case '人工编辑':
        await moveLegacy(preview, h, command);
      default:
        throw const FormatException('请在对应编辑页处理此历史。');
    }
  }

  Future<void> moveLegacy(
    ChangeDetail preview,
    Map<String, dynamic> history,
    Map<String, String> command,
  ) async {
    final record = preview.record;
    final id = record.bookId;
    final source = backend.shelf.books.firstWhere((b) => b.id == id).source!;
    try {
      final raw = record.domain == '结构'
          ? await api.editStructureDraft(
              sourceId: source.sourceId,
              revision: source.revision,
              draftJson: jsonEncode(history),
              commandJson: jsonEncode(command),
            )
          : await api.editManualDraft(
              sourceId: source.sourceId,
              revision: source.revision,
              draftJson: jsonEncode(history),
              commandJson: jsonEncode({
                ...command,
                'structure': backend.manuscript.structures[id],
              }),
            );
      check(record, preview.guard);
      final candidate = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final current =
          (candidate['history'] as List)[candidate['cursor'] as int];
      final base = backend.manuscript.effectiveBase(id);
      if (record.domain == '结构') {
        base['structure'] = current;
        // Validate the active manual version; archived redo states keep their
        // history and are checked against the structure when actually restored.
        if (backend.manuscript.manualEditDrafts[id] != null) {
          await api.editManualDraft(
            sourceId: source.sourceId,
            revision: source.revision,
            draftJson: jsonEncode(backend.manuscript.manualEditDrafts[id]),
            commandJson: jsonEncode({'op': 'inspect', 'structure': current}),
          );
          check(record, preview.guard);
        }
      } else {
        base['manual'] = (current as List).isEmpty
            ? null
            : {'kind': 'manual_batch', 'actions': current};
      }
      await backend.manuscript.validateEffectiveBase(id, base);
      check(record, preview.guard);
      backend.change(() {
        if (record.domain == '结构') {
          backend.manuscript.structureHistories[id] = candidate;
          backend.manuscript.structures[id] = (current as Map)
              .cast<String, dynamic>();
        } else {
          backend.manuscript.manualEditDrafts[id] = candidate;
        }
      });
    } on api.ApiError {
      throw const FormatException(
        '当前结构、人工编辑或清理之间存在依赖，暂不能恢复此步。请先撤销后续编辑；草稿和历史均已保留。',
      );
    }
  }
}
