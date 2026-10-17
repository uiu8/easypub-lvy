// 问题证据（CHK-021、CHK-039–041）：按问题类别给出默认对照对象——
// 两处位置（编号跳跃：前章末尾/后章开头；重复：第一处/第二处），或同一位置的两个版本（追溯原稿），
// 或单处位置 + 核对要点。超过两处位置时，位置下拉放在各侧卡片头部；追溯原稿只保留一个位置选择。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/chapter_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import 'comparison.dart';

class IssueEvidenceView extends StatefulWidget {
  const IssueEvidenceView({
    super.key,
    required this.session,
    required this.page,
    required this.issue,
    required this.onLocate,
    this.original = false,
    this.fallback,
  });
  final ChapterSession session;
  final ChapterIssuePage page;
  final ChapterIssue issue;
  final void Function(ChapterIssue) onLocate;
  final bool original;
  final ChapterIssueContext? fallback;
  @override
  State<IssueEvidenceView> createState() => _IssueEvidenceViewState();
}

class _IssueEvidenceViewState extends State<IssueEvidenceView> {
  late Future<List<ChapterIssueContext>> content;
  int leftIndex = 0, rightIndex = 1;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(IssueEvidenceView old) {
    super.didUpdateWidget(old);
    if (old.issue.id != widget.issue.id ||
        !identical(old.page, widget.page) ||
        (widget.issue.lines.isEmpty && old.fallback != widget.fallback)) {
      leftIndex = 0;
      rightIndex = 1;
      load();
    }
  }

  void load() {
    final session = widget.session;
    if (widget.fallback != null && widget.issue.anchors.isEmpty) {
      content = Future.value([widget.fallback!]);
      return;
    }
    content =
        session is ChapterIssueContextSession && widget.issue.lines.isNotEmpty
        ? Future.wait([
            for (var i = 0; i < widget.issue.lines.length; i++)
              (session as ChapterIssueContextSession).issueContext(
                widget.page,
                widget.issue,
                anchor: i,
              ),
          ])
        : Future.value([widget.fallback ?? const ChapterIssueContext()]);
  }

  List<ChapterContextRow> rows(ChapterIssueContext context, bool original) {
    final values = original ? context.originalRows : context.rows;
    if (values.isNotEmpty) return values;
    final text = original ? context.originalText : context.effectiveText;
    return text == null
        ? []
        : text.split('\n').map((text) => ChapterContextRow(text)).toList();
  }

  String titleAt(int index) => index < widget.issue.anchors.length
      ? widget.issue.anchors[index].title
      : '';

  Widget picker(int count, int side, int value) => DeskChoice<int>(
    compact: true,
    isExpanded: true,
    value: value,
    items: [
      for (var i = 0; i < count; i++)
        DropdownMenuItem(
          value: i,
          child: Text(
            '第 ${i + 1} 处 · ${titleAt(i)}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: (v) {
      if (v == null) return;
      setState(() {
        if (side == 0) {
          leftIndex = v;
        } else {
          rightIndex = v;
        }
      });
    },
  );

  ComparisonContent pane(
    List<ChapterIssueContext> data,
    int index,
    String label, {
    bool original = false,
    Widget? header,
  }) {
    final anchor = index < widget.issue.anchors.length
        ? widget.issue.anchors[index]
        : null;
    return ComparisonContent(
      label: label,
      title: titleAt(index),
      rows: rows(data[index], original),
      focusLine: original ? data[index].originalLine : anchor?.line,
      header: header,
      onLocate: original || anchor == null
          ? null
          : () => widget.onLocate(widget.issue.atAnchor(index)),
    );
  }

  String guidance() => switch (widget.issue.category) {
    'prose-heading' => '这一行应属于正文还是章节标题？确认是作者说明或普通句子后，可预览还原为正文；文字会保留。',
    'unrecognized-heading' ||
    'missing-heading-prefix' => '核对标题后的正文和相邻编号。确认是新章节后，预览识别结果。',
    'no-headings' => '尚未识别章节。使用“识别规则”选择标题格式，试匹配后预览完整章节树。',
    _ => widget.issue.evidence,
  };

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<ChapterIssueContext>>(
        future: content,
        builder: (context, snapshot) {
          final d = context.desk;
          if (snapshot.hasError) {
            return Align(
              alignment: Alignment.topCenter,
              child: DeskNote(
                deskErrorText(snapshot.error!, '请重新检查当前稿件后再定位或处理。'),
                title: '正文读取失败',
                tone: Tone.pen,
              ),
            );
          }
          if (!snapshot.hasData ||
              snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          if (data.isEmpty) {
            return Center(
              child: Text('此项没有可定位的文本。', style: ui(13, c: d.ink3)),
            );
          }
          final paired = data.length > 1 && !widget.original;
          final choose = data.length > 2;
          final a = leftIndex.clamp(0, data.length - 1),
              b = rightIndex.clamp(0, data.length - 1);
          final gap = widget.issue.category == 'number-gap';
          final duplicate = widget.issue.category.startsWith('duplicate');
          // 编号重复的两处是同号的两章，不是前后相邻章节。
          final twoPlaces =
              duplicate || widget.issue.subtype == 'repeated-number';
          if (paired) {
            return ComparisonWorkspace(
              key: ValueKey((widget.issue.id, a, b, false)),
              highlightDifferences: duplicate,
              left: pane(
                data,
                a,
                gap
                    ? '前章末尾'
                    : twoPlaces
                    ? '第一处'
                    : '前一个章节',
                header: choose ? picker(data.length, 0, a) : null,
              ),
              right: pane(
                data,
                b,
                gap
                    ? '后章开头'
                    : twoPlaces
                    ? '第二处'
                    : '后一个章节',
                header: choose ? picker(data.length, 1, b) : null,
              ),
            );
          }
          if (widget.original) {
            return ComparisonWorkspace(
              key: ValueKey((widget.issue.id, a, true)),
              versions: true,
              left: pane(
                data,
                a,
                '导入原稿',
                original: true,
                header: choose ? picker(data.length, 0, a) : null,
              ),
              right: pane(data, a, '当前编辑稿'),
            );
          }
          return ComparisonWorkspace(
            key: ValueKey((widget.issue.id, a, 'single')),
            left: pane(data, a, '问题所在位置'),
            right: ComparisonContent(
              label: '核对要点',
              rows: [ChapterContextRow(guidance())],
            ),
          );
        },
      );
}
