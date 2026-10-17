// 成品验收（D4-H，V8 按设计重写视图）：核验、包检查与打开成品逻辑沿用原实现。
import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;

import '../errors.dart';

import '../dialogs.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/output_history_service.dart';
import '../../application/conversion_desktop.dart';
import '../controls/controls.dart';

class OutputAcceptancePage extends StatefulWidget {
  const OutputAcceptancePage({
    super.key,
    required this.history,
    required this.desktop,
    required this.taskId,
    required this.onBack,
  });
  final OutputHistoryService history;
  final ConversionDesktop desktop;
  final String taskId;
  final VoidCallback onBack;
  @override
  State<OutputAcceptancePage> createState() => _OutputAcceptancePageState();
}

class _OutputAcceptancePageState extends State<OutputAcceptancePage> {
  bool loading = true, verified = false;
  int generation = 0;
  String error = '';
  OutputPackageInspection? package;
  @override
  void initState() {
    super.initState();
    inspect();
  }

  @override
  void didUpdateWidget(OutputAcceptancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId ||
        oldWidget.history != widget.history) {
      inspect();
    }
  }

  Future<void> inspect() async {
    final ticket = ++generation;
    final history = widget.history;
    final taskId = widget.taskId;
    bool current() => mounted && ticket == generation;
    setState(() {
      loading = true;
      verified = false;
      error = '';
      package = null;
    });
    try {
      await history.load();
      if (!current()) return;
      await history.verify(taskId);
      if (!current()) return;
      verified = true;
      final inspected = await history.inspectPackage(taskId);
      if (current()) setState(() => package = inspected);
    } catch (e) {
      if (current()) {
        setState(() => error = deskErrorText(e, '核验未完成，请检查任务回执和成品。'));
      }
    } finally {
      if (current()) setState(() => loading = false);
    }
  }

  Future<void> open(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '无法打开成品，请检查文件关联或路径。'));
      }
    }
  }

  Widget check(
    String title,
    String detail,
    String state,
    IconData icon, {
    bool passed = false,
  }) {
    final d = context.desk;
    final tone = state == '不一致' || state == '未通过'
        ? Tone.pen
        : state == '待验收' || state == '待核验' || state == '待对照'
        ? Tone.warn
        : passed
        ? Tone.ok
        : Tone.neutral;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: d.ink3),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ui(13, w: 600, c: d.ink)),
                Text(detail, style: ui(12, c: d.ink3, h: 1.5)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          DeskTag(state, tone),
        ],
      ),
    );
  }

  Widget field(String label, String value) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: ui(12, c: d.ink3)),
          ),
          Expanded(
            child: SelectableText(value, style: ui(12.5, c: d.ink)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.history.changes,
    builder: (context, _) {
      final d = context.desk;
      final record = widget.history.find(widget.taskId);
      if (record == null) {
        return Center(
          child: loading
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      error.isEmpty ? '找不到对应的成品记录。' : error,
                      style: ui(13, c: d.ink2),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        DeskButton('重新核验文件', onPressed: inspect),
                        DeskButton(
                          '返回转换任务',
                          quiet: true,
                          onPressed: widget.onBack,
                        ),
                      ],
                    ),
                  ],
                ),
        );
      }
      final fileMatches = verified && record.verificationCode == 'matches';
      final failed =
          !loading &&
          ((verified && !fileMatches) ||
              package?.status == 'failed' ||
              package?.metadataStatus == 'mismatch');
      final filename = record.path.replaceAll('\\', '/').split('/').last;
      final container = const {
        'kindle_container_checked',
        'kfx_container_checked',
      }.contains(package?.status);
      return DeskPageFrame(
        header: DeskPageHeader(
          title: '成品验收',
          subtitle: '文件与回执一致不代表已经通过 Kindle 真机阅读验收。',
          status: Icon(
            loading
                ? Icons.sync_rounded
                : failed
                ? Icons.error_outline_rounded
                : fileMatches
                ? Icons.check_circle_outline_rounded
                : Icons.info_outline_rounded,
            size: 18,
            color: failed ? d.tone(Tone.pen).$1 : d.ink2,
            semanticLabel: loading
                ? '正在核验'
                : failed
                ? '成品核验存在问题'
                : fileMatches
                ? '文件回执一致'
                : '核验尚未完成',
          ),
          actions: [
            DeskButton(
              '返回转换任务',
              icon: Icons.arrow_back_rounded,
              quiet: true,
              onPressed: widget.onBack,
            ),
            DeskButton(
              '重新核验文件',
              icon: Icons.refresh_rounded,
              onPressed: loading || record.busy ? null : inspect,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 4,
                child: DeskCard(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const DeskSectionTitle('成品文件'),
                        const SizedBox(height: 12),
                        Container(
                          height: 200,
                          decoration: BoxDecoration(
                            color: d.sunken,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: package?.cover != null
                              ? Image.memory(
                                  package!.cover!,
                                  cacheWidth: 384,
                                  cacheHeight: 384,
                                  fit: BoxFit.contain,
                                  semanticLabel: '实际成品封面',
                                  errorBuilder: (_, _, _) => Center(
                                    child: Text(
                                      '成品封面无法显示',
                                      style: ui(12, c: d.ink3),
                                    ),
                                  ),
                                )
                              : Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.menu_book_outlined,
                                        size: 48,
                                        color: d.lineStrong,
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        '成品封面尚未提取',
                                        style: ui(12, c: d.ink3),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          filename,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ui(14, w: 650, c: d.ink),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            DeskTag(
                              record.format == 'AZW3'
                                  ? 'Kindle AZW3'
                                  : record.format,
                              Tone.neutral,
                            ),
                            Text(
                              '${record.status} · ${loading ? '正在核验文件' : '核验结果见右侧'}',
                              style: ui(12, c: d.ink3),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        field('格式', record.format),
                        field('文件名', filename),
                        // 路径规范化，不再出现“flutter\\..\\”这类片段（TASK-028）。
                        field('位置', paths.normalize(record.directory)),
                        field(
                          '导出大小',
                          record.bytes == null
                              ? '回执未记录'
                              : formatFileSize(record.bytes!),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DeskButton(
                                '打开成品',
                                primary: true,
                                icon: Icons.open_in_new_rounded,
                                onPressed: () => open(
                                  () => widget.desktop.openOutput(record.path),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DeskButton(
                                '所在文件夹',
                                icon: Icons.folder_open_outlined,
                                onPressed: () => open(
                                  () => widget.desktop.openDirectory(
                                    record.directory,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 7,
                child: DeskCard(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    children: [
                      const DeskSectionTitle('成品检查'),
                      const SizedBox(height: 6),
                      check(
                        '文件完整性',
                        loading
                            ? '正在比较当前文件与导出回执…'
                            : !verified
                            ? '本次文件核验未完成，请重试。'
                            : record.verification.isEmpty
                            ? '尚无本次核验结果。'
                            : record.verification,
                        loading
                            ? '核验中'
                            : !verified
                            ? '待核验'
                            : fileMatches
                            ? '通过'
                            : '未通过',
                        Icons.check_circle_outline_rounded,
                        passed: !loading && fileMatches,
                      ),
                      if (container)
                        check(
                          'Kindle 容器',
                          package!.detail,
                          '通过',
                          Icons.inventory_2_outlined,
                          passed: true,
                        ),
                      check(
                        '章节与目录',
                        package?.inspected == true
                            ? '${package!.spineDocuments} 个阅读文档、${package!.headingCount} 个标题、${package!.checkedLinks} 条本地引用已检查。'
                            : container
                            ? '目录层级、阅读顺序和章节链接尚未核验。'
                            : package?.detail ??
                                  (loading ? '正在读取成品目录…' : '成品目录读取未完成，请重新核验。'),
                        loading
                            ? '核验中'
                            : package?.inspected == true
                            ? '通过'
                            : package?.status == 'failed'
                            ? '未通过'
                            : '待核验',
                        Icons.account_tree_outlined,
                        passed: package?.inspected == true,
                      ),
                      check(
                        '元信息与封面',
                        package?.metadataAvailable == true
                            ? '${[package!.title, package!.author, package!.language].where((v) => v.trim().isNotEmpty).join(' · ')}；${package!.cover != null || package!.coverMetadataPresent ? '已发现封面记录' : '成品未发现封面记录'}。${package!.metadataComparisonDetail}'
                            : container
                            ? '书名、作者、语言和实际内嵌封面尚未对照。'
                            : package?.detail ??
                                  (loading ? '正在读取实际元信息…' : '元信息读取未完成，请重新核验。'),
                        loading
                            ? '核验中'
                            : package?.metadataAvailable == true
                            ? switch (package!.metadataStatus) {
                                'matches' => '字段一致',
                                'mismatch' => '不一致',
                                _ => '待对照',
                              }
                            : package?.status == 'failed'
                            ? '未通过'
                            : '待核验',
                        Icons.image_outlined,
                        passed: package?.metadataStatus == 'matches',
                      ),
                      check(
                        '正文一致性',
                        package?.inspected == true
                            ? '${(package!.bodyBytes / 1024).toStringAsFixed(1)} KiB 正文已读取；仅为成品结构摘要，未与源稿逐段比对。'
                            : record.sourcePreserved
                            ? '导出回执确认原稿未改动；成品正文摘要尚未读取。'
                            : '尚无足够回执证据。',
                        '待核验',
                        Icons.article_outlined,
                      ),
                      check(
                        '正文图片与封面位置',
                        package?.inspected == true
                            ? '${package!.imageReferences} 处正文图片引用，清单中 ${package!.imageResources} 个图片资源；封面${package!.coverInSpine ? '进入' : '未进入'}阅读顺序。'
                            : '实际资源位置尚未核验。',
                        loading
                            ? '核验中'
                            : package?.inspected == true
                            ? '已读取'
                            : '待核验',
                        Icons.perm_media_outlined,
                        passed: package?.inspected == true,
                      ),
                      check(
                        'Kindle 阅读效果',
                        '仍需在目标设备检查翻页、目录与插图。',
                        '待验收',
                        Icons.tablet_android_outlined,
                      ),
                      if (error.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        DeskNote(error, tone: Tone.pen),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
