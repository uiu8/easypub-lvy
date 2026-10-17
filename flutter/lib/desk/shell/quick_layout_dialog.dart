import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/layout_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';

/// Applies an existing preset to the named book through the normal layout transaction.
class QuickLayoutDialog extends StatefulWidget {
  const QuickLayoutDialog({
    super.key,
    required this.library,
    required this.book,
  });
  final LibraryService library;
  final BookSummary book;
  @override
  State<QuickLayoutDialog> createState() => _QuickLayoutDialogState();
}

class _QuickLayoutDialogState extends State<QuickLayoutDialog> {
  late final session = widget.library.openLayout(widget.book.id);
  final entries = <({String group, LayoutPreset preset})>[];
  bool busy = true;
  String message = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      entries.add((group: '出厂默认排版', preset: await session.builtinPreset()));
      entries.addAll(session.presets.map((p) => (group: '本项目', preset: p)));
      entries.addAll(
        (await session.readGlobalPresets()).map(
          (p) => (group: '全局预设', preset: p),
        ),
      );
    } catch (e) {
      message = deskErrorText(e, '预设读取失败，请重新打开。');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> apply(({String group, LayoutPreset preset}) entry) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final plan = entry.group == '本项目'
          ? await session.previewPreset(entry.preset.name)
          : await session.preview(
              Map.fromEntries(
                entry.preset.values.entries.where(
                  (e) => layoutFields.contains(e.key),
                ),
              ),
            );
      await session.apply(plan);
      if (mounted) {
        Navigator.pop(
          context,
          entry.group == '出厂默认排版' ? entry.group : entry.preset.name,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          message = deskErrorText(e, '排版没有应用，请重试。');
        });
      }
    }
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 550),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(child: DeskText('选择排版', size: 20, bold: true)),
                  IconButton(
                    onPressed: busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              DeskText(
                '只应用到：${widget.book.title}',
                lines: 2,
                color: context.desk.ink2,
              ),
              const SizedBox(height: 12),
              if (message.isNotEmpty)
                DeskText(message, color: context.desk.pen),
              Expanded(
                child: busy
                    ? const Center(child: CircularProgressIndicator())
                    : DeskScrollArea(
                        builder: (controller) => ListView.builder(
                          controller: controller,
                          itemCount: entries.length,
                          itemBuilder: (_, index) {
                            final entry = entries[index];
                            return ListTile(
                              leading: const Icon(Icons.text_fields),
                              title: Text(
                                entry.group == '出厂默认排版'
                                    ? entry.group
                                    : entry.preset.name,
                              ),
                              subtitle: Text(
                                entry.group == '出厂默认排版'
                                    ? 'EasyPub 经典排版 · 两个全角空格缩进'
                                    : entry.group,
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => apply(entry),
                            );
                          },
                        ),
                      ),
              ),
              DeskText(
                '选择后保存到这本书；其他书籍保持各自排版。',
                size: 12,
                color: context.desk.ink2,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
