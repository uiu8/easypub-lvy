// 迁入 desk（library，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../errors.dart';

import 'package:flutter/services.dart';

import '../../application/book_information_service.dart';
import '../../application/source_refresh_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';

class SourceRefreshDialog extends StatefulWidget {
  const SourceRefreshDialog({
    super.key,
    required this.service,
    required this.bookId,
    this.onRestore,
  });
  final SourceRefreshService service;
  final String bookId;
  final Future<bool> Function(String)? onRestore;
  @override
  State<SourceRefreshDialog> createState() => _SourceRefreshDialogState();
}

class _SourceRefreshDialogState extends State<SourceRefreshDialog> {
  SourceRefreshPreview? preview;
  SourceRefreshResult? result;
  final fields = <String>{};
  bool busy = false,
      replaceBody = false,
      restoring = false,
      replaceImages = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    read();
  }

  Future<void> read() async {
    setState(() {
      busy = true;
      error = '';
      preview = null;
      fields.clear();
      replaceBody = false;
      replaceImages = false;
    });
    try {
      final value = await widget.service.previewSourceRefresh(widget.bookId);
      if (mounted) setState(() => preview = value);
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '来源读取失败，请检查文件路径和权限。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final value = await widget.service.applySourceRefresh(
        preview!,
        fields: Set.of(fields),
        replaceBody: replaceBody,
        replaceImages: replaceImages,
      );
      if (mounted) setState(() => result = value);
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '更新未采用，现有草稿保留。请检查资源和磁盘后重试。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String value(Object? value) =>
      value == null || value == '' ? '（空）' : value.toString();
  Future<void> restore() async {
    setState(() => restoring = true);
    try {
      final opened = await widget.onRestore!(result!.recoveryPath!);
      if (mounted && opened) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '恢复项目未打开，当前书稿保持不变。'));
      }
    } finally {
      if (mounted) setState(() => restoring = false);
    }
  }

  String origin(String key) {
    final source =
        (preview!.current['metadata_origins'] as Map?)?[key]?['source'];
    return switch (source) {
      'manual' => '手工',
      'folder_rule' => '目录规则',
      'imported' => '来源',
      'conversion' => '转换',
      _ => '未知来源',
    };
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !restoring,
    child: Dialog(
      backgroundColor: context.desk.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '刷新来源',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: busy || restoring
                        ? null
                        : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (busy) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Flexible(
                child: DeskScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (result != null) ...[
                        Text(result!.message),
                        if (result!.recoveryPath != null) ...[
                          const SizedBox(height: 16),
                          const Text('旧书稿恢复项目（包含本书及编辑历史）：'),
                          SelectableText(result!.recoveryPath!),
                          const SizedBox(height: 8),
                          const Text('打开旧书稿项目会切换工作区，未保存内容会先提示保存。'),
                          if (widget.onRestore != null)
                            FilledButton(
                              onPressed: restoring ? null : restore,
                              child: const Text('打开旧书稿项目'),
                            ),
                          TextButton.icon(
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: result!.recoveryPath!),
                            ),
                            icon: const Icon(Icons.copy),
                            label: const Text('复制恢复项目路径'),
                          ),
                        ],
                      ] else if (preview != null) ...[
                        SelectableText(preview!.path),
                        const SizedBox(height: 12),
                        Text(
                          preview!.bodyChanged
                              ? '正文来源已变化：${preview!.oldLines} 行 → ${preview!.newLines} 行'
                              : '正文来源未变化，现有章节与清理编辑可保留。',
                        ),
                        if (preview!.bodyChanged)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('采用新正文'),
                            subtitle: const Text(
                              '旧章节、清理和目录编辑留在恢复项目；不套用旧行号。旧插图保留为待定位，新稿使用新识别结果。',
                            ),
                            value: replaceBody,
                            onChanged: busy
                                ? null
                                : (v) => setState(() => replaceBody = v!),
                          ),
                        const SizedBox(height: 12),
                        if (preview!.imagesChanged)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('更新来源插图'),
                            subtitle: Text(
                              '${preview!.imageUpdateSummary}\n更新未手工修改的来源插图；手工位置、说明及移除保持。正文与章节编辑不变。',
                            ),
                            value: replaceImages,
                            onChanged: busy
                                ? null
                                : (v) => setState(() => replaceImages = v!),
                          ),
                        // 表头三态勾选（G-067）；默认不勾选，避免覆盖手工内容（G-068）。
                        SelectAllHeader(
                          selected: preview!.incoming.keys
                              .where(fields.contains)
                              .length,
                          total: preview!.incoming.length,
                          compact: false,
                          padding: EdgeInsets.zero,
                          onChanged: busy
                              ? null
                              : (v) => setState(() {
                                  v
                                      ? fields.addAll(preview!.incoming.keys)
                                      : fields.clear();
                                }),
                          body: const Text('选择采用的来源信息；未勾选的手工内容保持不变。'),
                        ),
                        const SizedBox(height: 8),
                        for (final entry in preview!.incoming.entries)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xffddd8cf),
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: CheckboxListTile(
                              title: Text(
                                '${bookInformationFields[entry.key] ?? '封面'} · 当前${origin(entry.key)}',
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '当前：${value(preview!.current[entry.key])}',
                                  ),
                                  Text('来源：${value(entry.value)}'),
                                ],
                              ),
                              value: fields.contains(entry.key),
                              onChanged: busy
                                  ? null
                                  : (v) => setState(() {
                                      v!
                                          ? fields.add(entry.key)
                                          : fields.remove(entry.key);
                                    }),
                            ),
                          ),
                        if (preview!.bodyChanged && !replaceBody)
                          const Text('保留旧正文时会保存旧正文副本，保证后续另存和重开仍可用。'),
                      ],
                      if (error.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            error,
                            style: TextStyle(color: context.desk.pen),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: busy || restoring
                        ? null
                        : () => Navigator.pop(context),
                    child: Text(result == null ? '取消' : '完成'),
                  ),
                  if (result == null) ...[
                    TextButton(
                      onPressed: busy ? null : read,
                      child: const Text('重新读取'),
                    ),
                    FilledButton(
                      onPressed: busy || preview == null ? null : apply,
                      child: Text(
                        replaceBody
                            ? '采用所选信息与新正文'
                            : replaceImages
                            ? '采用所选信息与插图'
                            : '采用并保留当前正文',
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
