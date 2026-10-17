// 元数据映射（D4-E，V8 按设计重写视图）：规则编辑、保存核对、逐书差异与保护字段逻辑沿用原实现。
import 'package:flutter/material.dart';

import '../errors.dart';

import 'dart:async';

import 'package:go_router/go_router.dart';

import '../dialogs.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/library_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../../application/metadata_mapping_service.dart';
import '../controls/controls.dart';
import '../pending/pending_changes.dart';
import 'favorites_dialog.dart';

class MappingNavigationGuard {
  Future<bool> Function()? check;
  Future<bool> canLeave() async => await check?.call() ?? true;
}

class MetadataMappingPage extends StatefulWidget {
  const MetadataMappingPage({
    super.key,
    required this.library,
    required this.picker,
    required this.navigation,
  });
  final MappingNavigationGuard navigation;
  final LibraryService library;
  final BookFilePicker picker;
  @override
  State<MetadataMappingPage> createState() => _MetadataMappingPageState();
}

class _MetadataMappingPageState extends State<MetadataMappingPage>
    with PendingReporter<MetadataMappingPage> {
  late final MappingSession session = widget.library.openMapping();
  late final List<MappingRule> rules = session.rules;
  final folder = TextEditingController();
  final values = {
    for (final field in mappingFields.keys) field: TextEditingController(),
  };
  final actions = <String, String>{};
  final overrides = <String, Set<String>>{};
  final restores = <String, Set<String>>{};
  int index = 0, diffIndex = 0;
  String scope = 'selected', message = '';
  bool busy = false, _dirty = false, _loading = false;
  WorkspaceAutosaveService? get autosave =>
      widget.library is WorkspaceAutosaveService
      ? widget.library as WorkspaceAutosaveService
      : null;
  String get draftKey =>
      'mapping:${session is ProjectMappingSession && (session as ProjectMappingSession).editingProject ? 'project' : 'global'}';
  bool get dirty => _dirty;
  set dirty(bool value) {
    _dirty = value;
    if (value) {
      rememberDraft();
    } else {
      autosave?.writeDraft(draftKey, null);
    }
  }

  void rememberDraft() {
    if (_loading) return;
    flush();
    autosave?.writeDraft(draftKey, {
      'rules': [for (final rule in rules) rule.toJson()],
      'index': index,
      'scope': scope,
      'editor': {
        'folder': folder.text,
        'values': {
          for (final entry in values.entries) entry.key: entry.value.text,
        },
        'actions': Map.of(actions),
      },
    });
  }

  void restoreDraft() {
    final draft = autosave?.readDraft(draftKey);
    if (draft == null) return;
    rules
      ..clear()
      ..addAll(
        (draft['rules'] as List).map(
          (value) => MappingRule.fromJson(value as Map),
        ),
      );
    index = (draft['index'] as int? ?? 0).clamp(
      0,
      rules.isEmpty ? 0 : rules.length - 1,
    );
    scope = draft['scope'] as String? ?? scope;
    _dirty = true;
    loadRule();
    final editor = draft['editor'] as Map?;
    if (editor != null) {
      folder.text = editor['folder'] as String;
      for (final key in values.keys) {
        values[key]!.text = (editor['values'] as Map)[key] as String? ?? '';
        actions[key] = (editor['actions'] as Map)[key] as String? ?? 'keep';
      }
    }
    message = '已恢复上次未应用的规则';
  }

  MappingPreview? preview;
  @override
  void initState() {
    super.initState();
    loadRule();
    restoreDraft();
    widget.navigation.check = confirmExit;
  }

  @override
  void dispose() {
    widget.navigation.check = null;
    folder.dispose();
    for (final value in values.values) {
      value.dispose();
    }
    super.dispose();
  }

  void loadRule() {
    _loading = true;
    final rule = rules.isEmpty ? null : rules[index];
    folder.text = rule?.folder ?? '';
    for (final key in mappingFields.keys) {
      actions[key] = rule?.fields[key]?['op'] ?? 'keep';
      values[key]!.text =
          rule?.fields[key]?['value'] ?? (key == 'cover_fit' ? 'contain' : '');
    }
    _loading = false;
  }

  void flush() {
    if (rules.isEmpty) return;
    rules[index] = rules[index].revised(folder.text.trim(), {
      for (final key in mappingFields.keys)
        key: {
          'op': actions[key]!,
          if (['set', 'fill_empty'].contains(actions[key]))
            'value': values[key]!.text,
        },
    });
  }

  Future<void> run(Future<void> Function() operation) async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() => message = deskErrorText(e, '操作没有完成。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseFavoriteFolder() async {
    if (busy) return;
    final path = await showDialog<String>(
      context: context,
      builder: (_) => FavoritesDialog(
        library: widget.library,
        picker: widget.picker,
        selectionLabel: '使用此目录',
      ),
    );
    if (path == null || !mounted) return;
    setState(() {
      folder.text = path;
      dirty = true;
    });
  }

  List<String> get targets {
    final selection = widget.library.selection.value;
    return switch (scope) {
      'all' => widget.library.books.value.map((b) => b.id).toList(),
      'current' => selection.current == null ? [] : [selection.current!],
      _ => selection.selected.toList(),
    };
  }

  Future<void> leave() async {
    if (mounted) context.go('/folders');
  }

  Future<bool> saveWithImpact() async {
    if (session is! MappingSaveReviewSession) {
      await session.saveRules(rules);
      return true;
    }
    final reviewed = session as MappingSaveReviewSession;
    final impact = await reviewed.previewRuleSave(rules);
    if (!mounted) return false;
    if (impact.items.isNotEmpty) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) {
          final d = context.desk;
          String value(Object? v) => v == null || v == ''
              ? '未填写'
              : (v is Map || v is List ? '已设置' : v.toString());
          return DeskDialog(
            title: '保存规则前核对',
            subtitle: '仅保存规则配置，不修改已有书稿。以下是以后按新规则重新应用时的差异，手工字段仍受保护。',
            closeTooltip: '返回编辑',
            width: 680,
            height: 480,
            footerLeft: Text(
              '已有 ${impact.items.length} 本书：${impact.changedBooks} 本可能变化，${impact.uncheckedBooks} 本未能核对。',
              style: ui(12, c: d.ink3),
            ),
            actions: [
              DeskButton(
                '返回编辑',
                quiet: true,
                onPressed: () => Navigator.pop(context, false),
              ),
              DeskButton(
                '仅保存规则',
                primary: true,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
            child: ListView.builder(
              itemCount: impact.items.length,
              itemBuilder: (_, index) {
                final item = impact.items[index], diff = item.diff;
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: d.line)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, style: ui(13, w: 600, c: d.ink)),
                      if (item.error != null)
                        Text(
                          '未核对：${item.error}',
                          style: ui(12, c: d.tone(Tone.warn).$1),
                        ),
                      if (diff != null && diff.changed.isEmpty)
                        Text('保持不变', style: ui(12, c: d.ink3)),
                      if (diff != null)
                        for (final key in diff.changed.where(
                          (key) =>
                              mappingFields.containsKey(key) ||
                              key == 'cover_crop' ||
                              key == 'cover_design',
                        ))
                          Text(
                            '${mappingFields[key] ?? (key == 'cover_crop' ? '封面裁切' : '封面方案')}：${value(diff.before[key])} → ${value(diff.after[key])}',
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: ui(12, c: d.ink2),
                          ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      );
      if (accepted != true || !mounted) return false;
    }
    await reviewed.saveReviewedRules(impact);
    return true;
  }

  Future<bool> confirmExit() async {
    if (busy) return false;
    if (dirty) rememberDraft();
    return await autosave?.flushWorkspace() ?? true;
  }

  void switchProjectScope(bool value) {
    if (busy || session is! ProjectMappingSession) return;
    setState(() {
      (session as ProjectMappingSession).selectProjectScope(value);
      rules
        ..clear()
        ..addAll(session.rules);
      index = 0;
      _dirty = false;
      preview = null;
      loadRule();
      restoreDraft();
      message = value ? '项目规则优先；未命中时使用全局规则。保存规则后启用，并随项目保存。' : '';
    });
    unawaited(confirmExit());
  }

  /// 生成逐书差异预览（底栏“预览逐书差异”与待应用“重新生成”共用）。
  Future<void> previewDifferences() async {
    flush();
    overrides.clear();
    restores.clear();
    final result = await session.preview(rules, targets);
    if (mounted) {
      preview = result;
      diffIndex = 0;
    }
  }

  Widget action(
    String title,
    VoidCallback callback, {
    bool primary = false,
    bool enabled = true,
    bool quiet = false,
    IconData? icon,
  }) => DeskButton(
    title,
    primary: primary,
    quiet: quiet,
    icon: icon,
    onPressed: busy || !enabled ? null : callback,
  );
  @override
  Widget build(BuildContext context) {
    // G-061：逐书差异已生成、尚未确认应用时登记为待应用；涉及多本书，确认时由会话复核。
    final pending = preview;
    reportPending(
      pending != null && pending.changedBooks > 0
          ? PendingChange(
              token: pending,
              domain: '元数据映射',
              summary: '${pending.changedBooks} 本书有变化',
              location: '/folders/mapping',
              discard: () {
                if (mounted && !busy) setState(() => preview = null);
              },
              regenerate: () {
                if (mounted && !busy) run(previewDifferences);
              },
            )
          : null,
    );
    return PopScope(
      canPop: !busy,
      child: DeskPageFrame(
        header: header(),
        child: preview == null ? editor() : differences(),
      ),
    );
  }

  Widget header() {
    final d = context.desk;
    final project = session is ProjectMappingSession
        ? session as ProjectMappingSession
        : null;
    return DeskPageHeader(
      title: '文件夹元数据映射',
      status: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (project != null) ...[
            DeskSegmented<bool>(
              value: project.editingProject,
              options: const {false: '全局规则', true: '项目规则'},
              onChanged: busy || preview != null ? null : switchProjectScope,
            ),
            const SizedBox(width: 8),
            Text('${rules.length} 条', style: ui(12, c: d.ink3)),
          ] else
            Text('全局规则 · ${rules.length} 条', style: ui(12, c: d.ink3)),
        ],
      ),
      actions: preview != null
          ? [
              action(
                '编辑规则',
                () => setState(() => preview = null),
                icon: Icons.edit_outlined,
                quiet: true,
              ),
            ]
          : [
              action(
                '返回文件夹',
                leave,
                icon: Icons.arrow_back_rounded,
                quiet: true,
              ),
              if (project != null && project.editingProject)
                action(
                  project.projectEnabled ? '项目优先：开' : '项目优先：关',
                  () => run(() async {
                    project.setProjectEnabled(!project.projectEnabled);
                    preview = null;
                    message = '已更新项目规则开关；已有书籍需要重新预览并确认，项目配置需保存项目。';
                  }),
                  quiet: true,
                ),
              if (project == null && session.projectRules.isNotEmpty)
                action(
                  '载入项目规则',
                  () => setState(() {
                    rules
                      ..clear()
                      ..addAll(session.projectRules);
                    index = 0;
                    loadRule();
                    dirty = true;
                    message = '已载入项目规则，请核对后保存到全局。';
                  }),
                  quiet: true,
                ),
              action(
                '放弃未应用规则',
                () => setState(() {
                  rules
                    ..clear()
                    ..addAll(session.rules);
                  index = 0;
                  loadRule();
                  dirty = false;
                  preview = null;
                  message = '已恢复已保存的规则';
                }),
                enabled: dirty,
                quiet: true,
              ),
              action(
                '保存规则配置',
                () => run(() async {
                  flush();
                  if (!await saveWithImpact()) return;
                  dirty = false;
                  message =
                      session is ProjectMappingSession &&
                          (session as ProjectMappingSession).editingProject
                      ? '项目规则已启用；请保存项目。已有书籍需预览差异后确认。'
                      : '规则已保存；之后导入自动匹配，已有书籍请先预览差异。';
                }),
                icon: Icons.save_outlined,
              ),
            ],
    );
  }

  /// 左栏：规则或书目列表，下方固定操作。
  Widget sideColumn({
    required String heading,
    required Widget list,
    List<Widget> bottom = const [],
  }) {
    final d = context.desk;
    return Container(
      width: 300,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(heading, style: ui(12, c: d.ink3)),
          ),
          Expanded(child: list),
          ...bottom,
        ],
      ),
    );
  }

  Widget sideRow({
    required bool current,
    required String title,
    required String detail,
    required String count,
    required VoidCallback? onTap,
  }) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: current ? d.surface : Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: current ? d.ink2 : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(13, w: current ? 650 : 560, c: d.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: mono(10.5, c: d.ink3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(count, style: ui(11.5, c: d.ink3)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget editor() {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              sideColumn(
                heading: '目录规则 · 全局保存 · 最多 128 条',
                list: rules.isEmpty
                    ? Center(
                        child: Text('还没有目录规则', style: ui(12.5, c: d.ink3)),
                      )
                    : ListView.builder(
                        itemCount: rules.length,
                        itemBuilder: (_, i) {
                          final fields = rules[i].fields.values
                              .where(
                                (f) => f['op'] != null && f['op'] != 'keep',
                              )
                              .length;
                          return sideRow(
                            current: index == i,
                            title: '目录规则 ${i + 1}',
                            detail: rules[i].folder.isEmpty
                                ? '尚未选择目录'
                                : rules[i].folder,
                            count: '$fields 字段',
                            onTap: busy
                                ? null
                                : () => setState(() {
                                    flush();
                                    index = i;
                                    loadRule();
                                  }),
                          );
                        },
                      ),
                bottom: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Text(
                      '采用最具体的目录规则：项目规则命中时优先；同一来源只项目规则优先，同层使用最具体目录。旧规则值按已记录的原值重新计算，手工值保留。',
                      style: ui(11.5, c: d.ink3, h: 1.5),
                    ),
                  ),
                  action('添加规则', () {
                    if (rules.length >= 128) return;
                    setState(() {
                      flush();
                      rules.add(
                        MappingRule.create('', {
                          'title': {'op': 'keep'},
                        }),
                      );
                      index = rules.length - 1;
                      loadRule();
                      dirty = true;
                    });
                  }, icon: Icons.add_rounded),
                ],
              ),
              Expanded(
                child: rules.isEmpty
                    ? Center(
                        child: Text(
                          '添加一条目录规则，设置需要补全或修改的字段。',
                          style: ui(13, c: d.ink2),
                        ),
                      )
                    : fieldEditor(),
              ),
            ],
          ),
        ),
        footer(previewing: false),
      ],
    );
  }

  Widget fieldEditor() {
    final d = context.desk;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 240, maxWidth: 620),
              child: TextField(
                controller: folder,
                enabled: !busy,
                style: ui(13, c: d.ink),
                decoration: const InputDecoration(hintText: '匹配目录'),
                onChanged: (_) => dirty = true,
              ),
            ),
            action(
              '浏览目录…',
              () => run(() async {
                final path = await widget.picker.chooseFolder();
                if (path != null && mounted) {
                  folder.text = path;
                  dirty = true;
                  flush();
                }
              }),
              icon: Icons.folder_open_outlined,
            ),
            action(
              '选收藏',
              chooseFavoriteFolder,
              icon: Icons.star_border_rounded,
            ),
            DeskButton(
              '删除当前规则',
              quiet: true,
              icon: Icons.delete_outline_rounded,
              onPressed: busy || rules.isEmpty
                  ? null
                  : () => setState(() {
                      rules.removeAt(index);
                      index = (index - 1).clamp(0, rules.length);
                      loadRule();
                      dirty = true;
                    }),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('按书稿所在目录匹配；文件名不会被解析成作者或其他字段。', style: ui(11.5, c: d.ink3)),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            children: const [
              SizedBox(width: 120, child: DeskColumnLabel('字段')),
              SizedBox(width: 172, child: DeskColumnLabel('应用方式')),
              Expanded(child: DeskColumnLabel('规则值')),
            ],
          ),
        ),
        const SizedBox(height: 4),
        for (final key in mappingFields.keys) fieldRow(key),
        const SizedBox(height: 10),
        Text(
          '字段可选：不改 / 设为指定值 / 仅填空值 / 清空；封面适配不提供清空。',
          style: ui(11.5, c: d.ink3),
        ),
      ],
    );
  }

  Widget fieldRow(String key) {
    final d = context.desk;
    final op = actions[key]!;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(mappingFields[key]!, style: ui(13, c: d.ink)),
          ),
          SizedBox(
            width: 160,
            child: DeskChoice<String>(
              key: ValueKey('$index-$key-$op'),
              initialValue: op,
              icon: const Icon(Icons.expand_more_rounded, size: 16),
              isExpanded: true,
              style: ui(12.5, c: d.ink),
              items: [
                for (final entry in mappingActions.entries)
                  if (key != 'cover_fit' || entry.key != 'clear')
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      actions[key] = v!;
                      dirty = true;
                    }),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ['set', 'fill_empty'].contains(op)
                ? key == 'cover_fit'
                      ? DeskChoice<String>(
                          key: ValueKey('fit-$index-${values[key]!.text}'),
                          initialValue: values[key]!.text,
                          style: ui(12.5, c: d.ink),
                          items: [
                            for (final e in {
                              'cover': '裁切铺满',
                              'contain': '完整显示',
                              'fill': '拉伸',
                            }.entries)
                              DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (v) => setState(() {
                                  values[key]!.text = v!;
                                  dirty = true;
                                }),
                        )
                      : TextField(
                          key: ValueKey('mapping-value-$key'),
                          controller: values[key],
                          enabled: !busy,
                          onChanged: (_) => dirty = true,
                          style: ui(13, c: d.ink),
                        )
                : Text(
                    op == 'clear' ? '移除已填写的值' : '保留每本书的值',
                    style: ui(12.5, c: d.ink3),
                  ),
          ),
        ],
      ),
    );
  }

  Widget footer({required bool previewing}) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message.isNotEmpty) ...[
            DeskInfoBar(message),
            const SizedBox(height: 8),
          ],
          if (busy) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: previewing
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '确认后更新 ${preview!.changedBooks} 本书',
                            style: ui(13, w: 600, c: d.ink),
                          ),
                          Text(
                            '仅应用到书籍草稿；不会覆盖原稿，也不自动保存规则配置。',
                            style: ui(11.5, c: d.ink3),
                          ),
                        ],
                      )
                    : Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('应用范围', style: ui(12, c: d.ink3)),
                          DeskSegmented<String>(
                            value: scope,
                            options: const {
                              'current': '当前书',
                              'selected': '已勾选书稿',
                              'all': '全部书稿',
                            },
                            onChanged: busy
                                ? null
                                : (v) => setState(() => scope = v),
                          ),
                          Text(
                            targets.isEmpty
                                ? '当前没有选择书籍；可以先保存全局规则，导入后再预览。'
                                : '本次 ${targets.length} 本书。全局规则用于后续导入，已有书修改需确认。',
                            style: ui(11.5, c: d.ink3),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 12),
              action(
                previewing ? '返回修改' : '取消',
                previewing
                    ? () => setState(() {
                        preview = null;
                        message = '';
                      })
                    : leave,
                quiet: true,
              ),
              const SizedBox(width: 8),
              action(
                previewing ? '确认应用到 ${preview!.changedBooks} 本书' : '预览逐书差异',
                () => run(() async {
                  if (previewing) {
                    message = await session.apply(preview!);
                    preview = null;
                  } else {
                    await previewDifferences();
                  }
                }),
                primary: true,
                icon: previewing ? Icons.check_rounded : Icons.compare_arrows,
                enabled: previewing || targets.isNotEmpty,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> chooseOverrides(
    MappingBookDiff item, {
    bool restore = false,
  }) async {
    final fields = (restore ? mappingFields.keys : item.actions.keys).where((
      key,
    ) {
      final origin =
          (item.before['metadata_origins'] as Map? ?? {})[key] as Map?;
      if (restore) {
        return origin?['source'] == 'manual' && origin?['baseline'] != null;
      }
      return item.actions[key] != 'keep' &&
          ['manual', 'unknown'].contains(origin?['source']);
    }).toList();
    final selected = {...?(restore ? restores : overrides)[item.bookId]};
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final d = context.desk;
          return DeskDialog(
            title: restore ? '恢复字段继承' : '覆盖受保护字段',
            subtitle: restore
                ? '解除所选字段的手工设置，按当前规则重新计算；无规则时恢复已记录的基础值。先预览差异，再确认采用。'
                : '仅覆盖明确勾选的字段。手工设置和旧项目来源未知的值默认保留；重新预览后仍需确认采用。',
            closeTooltip: '取消',
            width: 520,
            actions: [
              DeskButton(
                '取消',
                quiet: true,
                onPressed: () => Navigator.pop(context, false),
              ),
              DeskButton(
                '重新预览',
                primary: true,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (fields.isEmpty)
                  Text(
                    restore
                        ? '没有可恢复的手工字段；缺少基础值的旧记录不能自动恢复。'
                        : '当前规则没有需要覆盖的保护字段。',
                    style: ui(12.5, c: d.ink2),
                  ),
                // 表头三态勾选（G-067）；默认仍不勾选，只覆盖明确选中的字段（G-068）。
                if (fields.length > 1)
                  SelectAllHeader(
                    selected: fields.where(selected.contains).length,
                    total: fields.length,
                    padding: EdgeInsets.zero,
                    onChanged: (v) => update(() {
                      v ? selected.addAll(fields) : selected.removeAll(fields);
                    }),
                  ),
                for (final key in fields)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      restore && key == 'cover_path'
                          ? '封面图片（同时恢复方案与裁切）'
                          : mappingFields[key] ?? key,
                      style: ui(13, c: d.ink),
                    ),
                    value: selected.contains(key),
                    onChanged: (value) => update(() {
                      if (value == true) {
                        selected.add(key);
                      } else {
                        selected.remove(key);
                      }
                    }),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (!mounted || accepted != true) return;
    await run(() async {
      final proposed = <String, Set<String>>{
        for (final e in overrides.entries) e.key: {...e.value},
      };
      final proposedRestores = <String, Set<String>>{
        for (final e in restores.entries) e.key: {...e.value},
      };
      (restore ? proposedRestores : proposed)[item.bookId] = selected;
      (restore ? proposed : proposedRestores)[item.bookId]?.removeAll(selected);
      final updated = await (session as MappingOverrideSession)
          .previewOverrides(
            rules,
            targets,
            proposed,
            restoreFields: proposedRestores,
          );
      if (mounted) {
        overrides
          ..clear()
          ..addAll(proposed);
        restores
          ..clear()
          ..addAll(proposedRestores);
        preview = updated;
      }
    });
  }

  String originOf(MappingBookDiff item, String key) =>
      ((item.before['metadata_origins'] as Map? ?? {})[key] as Map?)?['source']
          as String? ??
      '';

  /// 应用方式列：保护字段、覆盖或恢复的选择与规则动作。
  String modeOf(MappingBookDiff item, String key) {
    final origin = originOf(item, key);
    if ((key == 'cover_design' || key == 'cover_crop') &&
        item.changed.contains(key)) {
      return '随封面更新';
    }
    if (['manual', 'unknown'].contains(origin)) {
      if (restores[item.bookId]?.contains(key) == true) return '已选择恢复继承';
      if (overrides[item.bookId]?.contains(key) == true) return '已选择覆盖保护值';
      return origin == 'unknown' ? '来源未知 · 保留' : '手工设置 · 保留';
    }
    if (item.changed.contains(key) &&
        (item.actions[key] == null || item.actions[key] == 'keep')) {
      return '恢复继承基础值';
    }
    return mappingActions[item.actions[key] ?? 'keep'] ?? '不改';
  }

  Widget differences() {
    final d = context.desk;
    final result = preview!, item = result.items[diffIndex];
    const displayFields = {
      ...mappingFields,
      'cover_design': '封面方案',
      'cover_crop': '封面裁切',
    };
    String display(Object? value) => value == null || value == ''
        ? '未填写'
        : value is Map
        ? (value['title']?.toString() ?? '已设置裁切')
        : {'cover': '裁切铺满', 'contain': '完整显示', 'fill': '拉伸'}[value] ??
              value.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              sideColumn(
                heading:
                    '逐书核对 · ${result.items.length} 本 · ${result.changedBooks} 本变化 · 预览期间尚未应用',
                list: ListView.builder(
                  itemCount: result.items.length,
                  itemBuilder: (_, i) {
                    final book = result.items[i];
                    return sideRow(
                      current: i == diffIndex,
                      title: '${book.before['title']}',
                      detail: book.folder ?? '未命中目录规则',
                      count: '${book.changed.length} 项变化',
                      onTap: busy ? null : () => setState(() => diffIndex = i),
                    );
                  },
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  children: [
                    Text(
                      '${item.before['title']} · 应用前后',
                      style: ui(14, w: 650, c: d.ink),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.folder == null
                          ? '未命中 · 回退可追溯的规则值，保留手工值'
                          : '采用${item.ruleScope == 'project' ? '项目规则' : '全局规则'}：${item.folder}',
                      style: ui(12.5, w: 600, c: d.ink2),
                    ),
                    Text(
                      '命中 ${item.candidates} 条；项目规则优先，同层使用最具体目录。${item.unavailableFolders.isEmpty ? '' : '\n未参与的离线或不可访问目录：${item.unavailableFolders.join('、')}'}',
                      style: ui(11.5, c: d.ink3, h: 1.5),
                    ),
                    const SizedBox(height: 8),
                    if (session is MappingOverrideSession)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          action(
                            '选择要覆盖的保护字段',
                            () => chooseOverrides(item),
                            quiet: true,
                          ),
                          action(
                            '恢复字段继承',
                            () => chooseOverrides(item, restore: true),
                            quiet: true,
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    DeskCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                            child: Row(
                              children: const [
                                Expanded(flex: 3, child: DeskColumnLabel('字段')),
                                Expanded(
                                  flex: 3,
                                  child: DeskColumnLabel('应用方式'),
                                ),
                                Expanded(flex: 4, child: DeskColumnLabel('原值')),
                                Expanded(
                                  flex: 4,
                                  child: DeskColumnLabel('应用后'),
                                ),
                              ],
                            ),
                          ),
                          for (final key in displayFields.keys)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                border: Border(top: BorderSide(color: d.line)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          displayFields[key]!,
                                          style: ui(12.5, c: d.ink2),
                                        ),
                                        Text(
                                          {
                                                'manual': '手工设置',
                                                'folder_rule': '目录规则',
                                                'imported': '入库原值',
                                              }[originOf(item, key)] ??
                                              '来源未知',
                                          style: ui(11, c: d.ink3),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: Text(
                                      modeOf(item, key),
                                      style: ui(12.5, c: d.ink2),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 4,
                                    child: Text(
                                      display(item.before[key]),
                                      style: ui(12.5, c: d.ink),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 4,
                                    child: Text(
                                      display(item.after[key]),
                                      style: ui(
                                        12.5,
                                        w: item.changed.contains(key)
                                            ? 600
                                            : 400,
                                        c: item.changed.contains(key)
                                            ? d.tone(Tone.ok).$1
                                            : d.ink3,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    const SizedBox(height: 10),
                    const DeskNote(
                      '目录、资源或书稿变化后需要重新预览；失败时不会应用本批修改。',
                      title: '逐书核对后再应用',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        footer(previewing: true),
      ],
    );
  }
}
