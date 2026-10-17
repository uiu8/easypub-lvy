// 迁入 desk（resources，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/resource_service.dart';
import '../../application/book_information_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';

class ResourceRelinkDialog extends StatefulWidget {
  const ResourceRelinkDialog({
    super.key,
    required this.session,
    required this.resources,
    required this.pickFolder,
    required this.pickImage,
  });
  final ResourceSession session;
  final List<BookResource> resources;
  final Future<String?> Function() pickFolder, pickImage;
  @override
  State<ResourceRelinkDialog> createState() => _ResourceRelinkDialogState();
}

class _ResourceRelinkDialogState extends State<ResourceRelinkDialog> {
  late final rows = widget.resources.where((r) => r.editable).toList();
  final folder = TextEditingController();
  Map<int, String> paths = {};
  Map<int, CoverImageEvidence?> matches = {};
  BookInformationPreview? plan;
  String error = '';
  bool busy = false;
  @override
  void dispose() {
    folder.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = deskErrorText(e, '资源检查失败，整批未应用。请重新检查路径和当前书稿。');
          plan = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> scan() async {
    final base = folder.text.trim();
    if (base.isEmpty) throw const FormatException('请选择新的资源文件夹。');
    final candidates = {for (final row in rows) row.index: '$base/${row.name}'};
    final checked = await widget.session.inspectRelink(candidates);
    if (mounted) {
      setState(() {
        paths = candidates;
        matches = checked;
        plan = null;
      });
    }
  }

  Future<void> chooseFolder() => run(() async {
    final value = await widget.pickFolder();
    if (!mounted || value == null) return;
    folder.text = value;
    await scan();
  });
  Future<void> preview() => run(() async {
    if (paths.isEmpty) await scan();
    final result = await widget.session.relink(paths);
    if (mounted) setState(() => plan = result);
  });
  Future<void> apply() => run(() async {
    await widget.session.apply(plan!);
    if (mounted) Navigator.pop(context, true);
  });
  String matchText(BookResource row) {
    if (!matches.containsKey(row.index)) return '等待选择文件夹';
    final candidate = matches[row.index];
    if (candidate == null) return '文件不可用或格式不支持';
    if (row.image == null) return '原指纹不可用，无法比对';
    if (candidate.sha256 == row.image!.sha256) return '内容一致';
    final candidateName = paths[row.index]!
        .replaceAll('\\', '/')
        .split('/')
        .last;
    return candidateName == row.name ? '同名但内容不同' : '内容不同';
  }

  String treatment(BookResource row) {
    if (!matches.containsKey(row.index)) return plan == null ? '待匹配' : '不更改';
    if (matches[row.index] == null) return '需重新选择';
    return row.image?.sha256 == matches[row.index]!.sha256 ? '可重新绑定' : '需确认';
  }

  Widget cells(List<Widget> children) => Row(
    children: [
      for (var i = 0; i < children.length; i++)
        Expanded(flex: i == 2 ? 2 : 3, child: children[i]),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final unavailable = rows.where((r) => r.image == null).length;
    return PopScope(
      canPop: !busy,
      child: Dialog(
        backgroundColor: context.desk.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: 680,
          height: 496,
          child: Padding(
            padding: const EdgeInsets.all(26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: DeskText('重新定位资源', size: 22, bold: true),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: busy
                          ? null
                          : () => Navigator.pop(context, false),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xffFCF3DE),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: Color(0xffA46D13),
                        size: 18,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DeskText(
                              unavailable > 0
                                  ? '$unavailable 个资源的原路径不可访问或无法读取'
                                  : '重新定位 ${rows.length} 个图片引用',
                              bold: true,
                              color: const Color(0xffA46D13),
                            ),
                            const DeskText(
                              '以文件名与可用指纹比对；内容不同或无法比对时，需要明确确认。',
                              size: 12,
                              color: Color(0xffA46D13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (plan == null)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DeskText(
                              '新资源文件夹',
                              size: 12,
                              color: context.desk.ink2,
                            ),
                            const SizedBox(height: 5),
                            TextField(
                              controller: folder,
                              enabled: !busy,
                              onChanged: (_) => setState(() {
                                paths = {};
                                matches = {};
                              }),
                              onSubmitted: (_) => run(scan),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      DeskButton(
                        '浏览文件夹',
                        icon: Icons.folder_open,
                        onPressed: busy ? null : chooseFolder,
                      ),
                    ],
                  )
                else
                  DeskText(
                    '确认以下新路径。图注、顺序和原稿位置保留；原文件不变。',
                    size: 12,
                    color: context.desk.ink2,
                  ),
                const SizedBox(height: 16),
                Container(
                  color: context.desk.canvas,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: cells([
                    DeskText('资源', size: 12, color: context.desk.ink2),
                    DeskText('匹配结果', size: 12, color: context.desk.ink2),
                    DeskText('处理', size: 12, color: context.desk.ink2),
                  ]),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final row = rows[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: context.desk.line),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            cells([
                              Tooltip(
                                message: row.path,
                                child: DeskText(row.name, bold: true, lines: 1),
                              ),
                              DeskText(
                                matchText(row),
                                size: 12,
                                color: context.desk.ink2,
                              ),
                              Tooltip(
                                message: '为此资源单独浏览图片',
                                child: InkWell(
                                  onTap: busy || plan != null
                                      ? null
                                      : () => run(() async {
                                          final path = await widget.pickImage();
                                          if (!mounted || path == null) return;
                                          final checked = await widget.session
                                              .inspectRelink({row.index: path});
                                          if (mounted) {
                                            setState(() {
                                              paths = {
                                                ...paths,
                                                row.index: path,
                                              };
                                              matches = {
                                                ...matches,
                                                ...checked,
                                              };
                                            });
                                          }
                                        }),
                                  child: DeskText(
                                    treatment(row),
                                    size: 12,
                                    color: context.desk.ink2,
                                  ),
                                ),
                              ),
                            ]),
                            if (plan != null &&
                                paths.containsKey(row.index)) ...[
                              const SizedBox(height: 6),
                              SelectableText(
                                '→ ${paths[row.index]}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.desk.ink2,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
                if (error.isNotEmpty) DeskText(error, size: 12),
                const Divider(height: 32),
                Row(
                  children: [
                    DeskButton(
                      '取消',
                      quiet: true,
                      onPressed: busy
                          ? null
                          : () => Navigator.pop(context, false),
                    ),
                    if (plan != null)
                      DeskButton(
                        '返回选择',
                        quiet: true,
                        onPressed: busy
                            ? null
                            : () => setState(() => plan = null),
                      ),
                    const Spacer(),
                    DeskButton(
                      plan == null ? '预览并确认' : '确认重新定位',
                      primary: true,
                      onPressed: busy
                          ? null
                          : plan == null
                          ? preview
                          : apply,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
