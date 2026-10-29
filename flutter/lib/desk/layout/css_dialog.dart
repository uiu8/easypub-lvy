// 迁入 desk（layout，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/layout_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../controls/controls.dart';
import 'css_editor.dart';
import '../tokens.dart';
import '../dialogs.dart';

class CssDialog extends StatefulWidget {
  const CssDialog({
    super.key,
    required this.session,
    required this.importFile,
    this.autosave,
    this.draftKey,
  });
  final LayoutSession session;
  final WorkspaceAutosaveService? autosave;
  final String? draftKey;
  final Future<({String text, String base})?> Function() importFile;
  @override
  State<CssDialog> createState() => _CssDialogState();
}

class _CssDialogState extends State<CssDialog> {
  late final initial = widget.session.savedCss;
  late final draft = widget.draftKey == null
      ? null
      : widget.autosave?.readDraft(widget.draftKey!);
  void remember() {
    if (widget.draftKey != null) {
      widget.autosave?.writeDraft(widget.draftKey!, {
        'text': css.text,
        'base': base.text,
      });
    }
  }

  void discard() {
    if (widget.draftKey != null) {
      widget.autosave?.writeDraft(widget.draftKey!, null);
    }
  }

  late final css = TextEditingController(
    text: draft?['text'] as String? ?? initial['text'] as String,
  );
  late final base = TextEditingController(
    text: draft?['base'] as String? ?? initial['base'] as String,
  );
  CssPreview? preview;
  bool busy = false;
  String message = '';
  @override
  void dispose() {
    css.dispose();
    base.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          preview = null;
          message = deskErrorText(error, '检查或保存失败，请核对文件、参数与书稿状态后重新检查。');
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> inspect() => run(() async {
    final result = await widget.session.previewCss(css.text, base.text);
    if (mounted) setState(() => preview = result);
  });
  Future<void> import() => run(() async {
    final result = await widget.importFile();
    if (mounted && result != null) {
      setState(() {
        css.text = result.text;
        base.text = result.base;
        preview = null;
      });
      remember();
    }
  });
  Future<void> save() async {
    final frozen = preview!;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => DeskAlert(
        title: const Text('确认 CSS 变更'),
        content: SizedBox(
          width: 640,
          height: 340,
          child: DeskScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('保存前'),
                SelectableText(
                  '${frozen.change.before['additional_css_base']}\n${frozen.change.before['additional_css']}',
                ),
                const Divider(),
                const Text('保存后'),
                SelectableText(
                  '${frozen.change.after['additional_css_base']}\n${frozen.change.after['additional_css']}',
                ),
                if (frozen.change.changed.contains('additional_css_bundle'))
                  const Text('原离线资源快照将解除；保存项目时重新收集依赖。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认保存 CSS'),
          ),
        ],
      ),
    );
    if (!mounted || accepted != true) return;
    await run(() async {
      await widget.session.applyCss(frozen);
      if (!mounted) return;
      discard();
      Navigator.pop(context, true);
    });
  }

  void invalidate(String _) {
    setState(() => preview = null);
    remember();
  }

  Widget dependencyTable(CssPreview report) {
    Widget row(
      String name,
      String type,
      String status, {
      bool header = false,
      String? detail,
    }) => Container(
      color: header ? context.desk.canvas : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Tooltip(
              message: detail ?? name,
              child: DeskText(
                name,
                size: 13,
                bold: !header,
                lines: 3,
                color: header ? context.desk.ink2 : context.desk.ink,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: DeskText(type, size: 13, color: context.desk.ink2)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: DeskText(status, size: 13, color: context.desk.ink2),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row('依赖', '类型', '状态', header: true),
        Expanded(
          child: report.files.isEmpty && report.issues.isEmpty
              ? Center(child: DeskText('没有本地文件依赖', color: context.desk.ink2))
              : ListView.separated(
                  itemCount: report.issues.length + report.files.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    if (index < report.issues.length) {
                      return row(report.issues[index], '依赖问题', '需要处理');
                    }
                    final path = report.files[index - report.issues.length];
                    final ext = path.split('.').last.toLowerCase();
                    final type = ext == 'css'
                        ? '样式'
                        : ['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(ext)
                        ? '图片'
                        : ['woff', 'woff2', 'ttf', 'otf'].contains(ext)
                        ? '字体'
                        : '文件';
                    return row(
                      path.replaceAll('\\', '/').split('/').last,
                      type,
                      report.issues.isEmpty ? '可收集' : '已读取 · 待解决问题',
                      detail: path,
                    );
                  },
                ),
        ),
        const SizedBox(height: 8),
        DeskText(
          report.issues.isEmpty
              ? '依赖检查通过 · ${report.bytes} 字节 · ${report.change.changed.length} 项变更'
              : '存在 ${report.issues.length} 项依赖问题，不能保存',
          size: 12,
          color: context.desk.ink2,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: DeskDialog(
      closeTooltip: '关闭',
      title: '附加 CSS',
      width: 760,
      actions: [
        DeskButton(
          '放弃未应用内容',
          quiet: true,
          onPressed: busy
              ? null
              : () {
                  discard();
                  Navigator.pop(context, false);
                },
        ),
        DeskButton(
          '确认保存',
          primary: true,
          onPressed: busy || preview == null || preview!.issues.isNotEmpty
              ? null
              : save,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DeskButton(
                '导入 CSS',
                icon: Icons.file_open_outlined,
                onPressed: busy ? null : import,
              ),
              const SizedBox(width: 10),
              DeskButton(
                '检查依赖',
                icon: Icons.fact_check_outlined,
                onPressed: busy ? null : inspect,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            height: 190,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: context.desk.sunken,
              border: Border.all(color: context.desk.line),
              borderRadius: BorderRadius.circular(7),
            ),
            child: CssEditor(
              key: const ValueKey('css-code-editor'),
              controller: css,
              enabled: !busy,
              onChanged: invalidate,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('css-base'),
            controller: base,
            enabled: !busy,
            onChanged: invalidate,
            decoration: const InputDecoration(labelText: '本地依赖所在目录'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: preview == null
                ? Center(
                    child: DeskText(
                      initial['offline'] == true
                          ? '当前使用离线资源快照；修改样式或目录后需重新检查依赖。'
                          : '检查后列出真实依赖；尚未修改书籍。',
                      color: context.desk.ink2,
                    ),
                  )
                : dependencyTable(preview!),
          ),
          if (message.isNotEmpty) DeskText(message, size: 12),
        ],
      ),
    ),
  );
}
