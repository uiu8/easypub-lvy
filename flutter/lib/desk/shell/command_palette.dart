// 命令面板（G-062）：Ctrl+K 或标题栏搜索框打开。每条命令带稳定功能 ID；
// 支持中文、拼音首字母与功能 ID 检索；不可用命令显示原因且不能执行。
// 面板只负责跳转与打开既有入口，不直接执行任何修改正文的应用动作。
// V70（G-075/076）：未输入时最上方列出“最近使用”；书名一类命令只在输入后出现。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';
import '../widgets.dart';

class DeskCommand {
  const DeskCommand({
    required this.id,
    required this.label,
    required this.group,
    required this.initials,
    required this.run,
    this.icon = Icons.chevron_right_rounded,
    this.keywords = '',
    this.shortcut,
    this.disabledReason,
    this.searchOnly = false,
  });

  /// 功能对照表中的稳定 ID，例如 G-005。
  final String id;
  final String label, group, initials, keywords;
  final String? shortcut, disabledReason;
  final IconData icon;
  final VoidCallback run;

  /// 只在输入后出现（例如按书名切换），未输入时不占面板。
  final bool searchOnly;
  bool get enabled => disabledReason == null;

  /// “最近使用”记录用的键：同一功能 ID 下可能有几条命令（如四种格式的转换）。
  String get key => '$id|$label';

  DeskCommand inGroup(String name) => DeskCommand(
    id: id,
    label: label,
    group: name,
    initials: initials,
    run: run,
    icon: icon,
    keywords: keywords,
    shortcut: shortcut,
    disabledReason: disabledReason,
    searchOnly: searchOnly,
  );

  bool matches(String query) {
    final q = query.trim().toLowerCase().replaceAll(' ', '');
    if (q.isEmpty) return true;
    return label.toLowerCase().contains(q) ||
        keywords.toLowerCase().contains(q) ||
        initials.contains(q) ||
        id.toLowerCase().replaceAll('-', '').contains(q.replaceAll('-', ''));
  }
}

/// [recent] 为最近执行命令的 [DeskCommand.key]（最近的在前）；[onRun] 在执行前调用，用于记录。
/// [more] 是打开后才读取的命令（R1：当前书的章节），读到后并入，不耽误面板打开。
Future<void> showDeskCommandPalette(
  BuildContext context,
  List<DeskCommand> commands, {
  List<String> recent = const [],
  void Function(DeskCommand command)? onRun,
  Future<List<DeskCommand>>? more,
}) async {
  final chosen = await showDialog<DeskCommand>(
    context: context,
    barrierColor: context.desk.shadowInk.withValues(alpha: .18),
    builder: (_) =>
        _CommandPalette(commands: commands, recent: recent, more: more),
  );
  if (chosen == null) return;
  onRun?.call(chosen);
  chosen.run();
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({
    required this.commands,
    this.recent = const [],
    this.more,
  });
  final List<DeskCommand> commands;
  final List<String> recent;
  final Future<List<DeskCommand>>? more;
  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final query = TextEditingController();
  final scroll = ScrollController();
  int index = 0;
  List<DeskCommand> extra = const [];

  @override
  void initState() {
    super.initState();
    widget.more?.then((value) {
      if (mounted) setState(() => extra = value);
    }, onError: (_) {});
  }

  List<DeskCommand> get visible {
    if (query.text.trim().isNotEmpty) {
      return [
        ...widget.commands,
        ...extra,
      ].where((c) => c.matches(query.text)).toList();
    }
    final byKey = {for (final c in widget.commands) c.key: c};
    final recent = [for (final k in widget.recent) ?byKey[k]];
    final keys = {for (final c in recent) c.key};
    return [
      for (final c in recent) c.inGroup('最近使用'),
      for (final c in widget.commands)
        if (!c.searchOnly && !keys.contains(c.key)) c,
    ];
  }

  @override
  void dispose() {
    query.dispose();
    scroll.dispose();
    super.dispose();
  }

  void move(int delta) {
    final items = visible;
    if (items.isEmpty) return;
    setState(() => index = (index + delta) % items.length);
    final target = (index * 36.0) - 120;
    if (scroll.hasClients) {
      scroll.jumpTo(target.clamp(0, scroll.position.maxScrollExtent));
    }
  }

  void choose(DeskCommand command) {
    if (!command.enabled) return;
    Navigator.pop(context, command);
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final items = visible;
    if (index >= items.length) index = 0;
    String? lastGroup;
    return Align(
      alignment: const Alignment(0, -.62),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          clipBehavior: Clip.antiAlias,
          width: 560,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .66,
          ),
          decoration: BoxDecoration(
            color: d.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: d.line),
            boxShadow: d.shadow3,
          ),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  move(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
              const SingleActivator(LogicalKeyboardKey.enter): () {
                if (items.isNotEmpty) choose(items[index]);
              },
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded, size: 18, color: d.ink3),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('desk-command-query'),
                          controller: query,
                          autofocus: true,
                          style: ui(14.5, c: d.ink),
                          decoration: InputDecoration(
                            hintText: '输入命令、页面、拼音首字母或功能编号',
                            hintStyle: ui(14.5, c: d.ink3),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() => index = 0),
                          onSubmitted: (_) {
                            if (items.isNotEmpty) choose(items[index]);
                          },
                        ),
                      ),
                      const Kbd('Esc'),
                    ],
                  ),
                ),
                Container(height: 1, color: d.line),
                Flexible(
                  child: items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '没有匹配的命令',
                            textAlign: TextAlign.center,
                            style: ui(13, c: d.ink3),
                          ),
                        )
                      : ListView(
                          controller: scroll,
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          children: [
                            for (var i = 0; i < items.length; i++) ...[
                              if (items[i].group != lastGroup)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    4,
                                  ),
                                  child: Text(
                                    lastGroup = items[i].group,
                                    style: ui(11, w: 600, c: d.ink3),
                                  ),
                                ),
                              _CommandRow(
                                command: items[i],
                                active: i == index,
                                onTap: () => choose(items[i]),
                                onHover: () => setState(() => index = i),
                              ),
                            ],
                          ],
                        ),
                ),
                Container(height: 1, color: d.line),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      const Kbd('↑↓'),
                      const SizedBox(width: 6),
                      Text('选择', style: ui(11.5, c: d.ink3)),
                      const SizedBox(width: 14),
                      const Kbd('Enter'),
                      const SizedBox(width: 6),
                      Text('打开', style: ui(11.5, c: d.ink3)),
                      const Spacer(),
                      Text('面板只打开页面与入口，不直接改动书稿', style: ui(11.5, c: d.ink3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({
    required this.command,
    required this.active,
    required this.onTap,
    required this.onHover,
  });
  final DeskCommand command;
  final bool active;
  final VoidCallback onTap, onHover;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final enabled = command.enabled;
    return MouseRegion(
      onHover: (_) => onHover(),
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active ? d.accentSoft : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(command.icon, size: 17, color: enabled ? d.ink2 : d.ink3),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: command.label,
                        style: ui(13.5, w: 500, c: enabled ? d.ink : d.ink3),
                      ),
                      if (!enabled)
                        TextSpan(
                          text: '  ${command.disabledReason}',
                          style: ui(12, c: d.ink3),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (command.shortcut != null) ...[
                Kbd(command.shortcut!),
                const SizedBox(width: 8),
              ],
              Text(command.id, style: mono(10.5, c: d.ink3)),
            ],
          ),
        ),
      ),
    );
  }
}
