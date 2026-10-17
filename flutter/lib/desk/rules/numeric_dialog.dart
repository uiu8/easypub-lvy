// 数字章节（V25，CH-263）：把原来分散在识别规则开关、清理预设和修复批次里的数字标题处理合成一个流程：
// 列出全书的数字标题 → 预览“识别为章节，并改写为第X章 标题” → 勾选已核对 → 作为一批应用（可整批撤销）。
// 预览与应用都走本书识别规则会话（Rust 识别器），只在本书规则上打开“识别纯数字标题”，其余规则不变。
// 参考原 EasyPub Modern 的 ChapterTitleNormalizer：“12、标题”→“第十二章 标题”。
import 'package:flutter/material.dart';

import '../../application/chapter_rules_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../errors.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 打开数字章节对话框；应用后返回 true。
Future<bool> showNumericChaptersDialog(
  BuildContext context, {
  required ChapterRulesService service,
  required String bookId,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NumericChaptersDialog(session: service.openRules(bookId)),
    ) ==
    true;

class NumericChaptersDialog extends StatefulWidget {
  const NumericChaptersDialog({super.key, required this.session});
  final ChapterRulesSession session;
  @override
  State<NumericChaptersDialog> createState() => _NumericChaptersDialogState();
}

class _NumericChaptersDialogState extends State<NumericChaptersDialog> {
  Map<String, dynamic>? base;
  ChapterRulesPreview? preview;
  bool normalize = true, busy = true, confirmed = false;
  String error = '';
  final minimum = TextEditingController();
  final search = TextEditingController();
  int ticket = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    minimum.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final data = await widget.session.load();
      base = Map<String, dynamic>.from(data['rules'] as Map);
      minimum.text = '${base!['numeric_minimum_body_lines'] ?? 2}';
      await run();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = deskErrorText(e, '没有读到本书识别规则，请稍后重试。');
        });
      }
    }
  }

  /// 本书规则 + 打开纯数字标题（+ 规范为“第X章 标题”）。
  Map<String, dynamic> rules() => {
    ...base!,
    'numeric': true,
    'normalize_numeric_titles': normalize,
    'numeric_minimum_body_lines':
        int.tryParse(minimum.text.trim()) ??
        base!['numeric_minimum_body_lines'] ??
        2,
  };

  Future<void> run() async {
    final mine = ++ticket;
    setState(() {
      busy = true;
      confirmed = false;
      preview = null;
      error = '';
    });
    try {
      final next = await widget.session.preview(
        rules(),
        preserveDecisions: true,
      );
      if (!mounted || mine != ticket) return;
      setState(() => preview = next);
    } catch (e) {
      if (mounted && mine == ticket) {
        setState(() => error = deskErrorText(e, '预览没有完成，请检查行数后重试。'));
      }
    } finally {
      if (mounted && mine == ticket) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    setState(() => busy = true);
    try {
      await widget.session.apply(preview!);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = deskErrorText(e, '没有应用：书稿或规则已变化，请重新预览。');
        });
      }
    }
  }

  List<Map> get changes => [
    for (final c in (preview?.data['changes'] as List? ?? const []).cast<Map>())
      if (c['kind'] == 'added' || c['kind'] == 'changed') c,
  ];

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final all = changes;
    final added = all.where((c) => c['kind'] == 'added').length;
    final renamed = all.length - added;
    final removed = (preview?.data['changes'] as List? ?? const [])
        .cast<Map>()
        .where((c) => c['kind'] == 'removed')
        .length;
    final query = search.text.trim();
    final shown = query.isEmpty
        ? all
        : all
              .where(
                (c) => '${c['line']} ${c['before'] ?? ''} ${c['after']}'
                    .contains(query),
              )
              .toList();
    return DeskDialog(
      title: '数字章节',
      subtitle: '列出全书的数字标题，预览识别与改写；确认后作为一批应用，可整批撤销。原稿不变。',
      closeTooltip: '取消',
      width: 760,
      height: 640,
      busy: busy && preview != null,
      scrollBody: false,
      footerLeft: InkWell(
        key: const ValueKey('numeric-confirm'),
        onTap: busy || all.isEmpty
            ? null
            : () => setState(() => confirmed = !confirmed),
        borderRadius: BorderRadius.circular(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: confirmed,
              onChanged: busy || all.isEmpty
                  ? null
                  : (v) => setState(() => confirmed = v ?? false),
            ),
            Text('已核对数字标题', style: ui(12.5, c: d.ink2)),
          ],
        ),
      ),
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () => Navigator.pop(context, false),
        ),
        DeskButton(
          '应用 ${all.length} 项',
          key: const ValueKey('numeric-apply'),
          primary: true,
          disabledReason: all.isEmpty ? '没有需要处理的数字标题' : '先勾选“已核对数字标题”',
          onPressed: !busy && confirmed && all.isNotEmpty ? apply : null,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InkWell(
                key: const ValueKey('numeric-normalize'),
                onTap: busy || base == null
                    ? null
                    : () {
                        normalize = !normalize;
                        run();
                      },
                borderRadius: BorderRadius.circular(6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: normalize,
                      onChanged: busy || base == null
                          ? null
                          : (v) {
                              normalize = v ?? true;
                              run();
                            },
                    ),
                    Text('改写为“第X章 标题”', style: ui(12.5, c: d.ink)),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('标题后至少', style: ui(12.5, c: d.ink2)),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 52,
                    child: TextField(
                      key: const ValueKey('numeric-minimum'),
                      controller: minimum,
                      enabled: !busy && base != null,
                      style: ui(12.5, c: d.ink),
                      textAlign: TextAlign.center,
                      decoration: deskInput(context),
                      onSubmitted: (_) => run(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('行正文', style: ui(12.5, c: d.ink2)),
                ],
              ),
              DeskButton(
                '重新预览',
                quiet: true,
                icon: Icons.refresh_rounded,
                onPressed: busy || base == null ? null : run,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (error.isNotEmpty) ...[
            DeskNote(error, tone: Tone.pen),
            const SizedBox(height: 8),
          ],
          if (preview == null && error.isEmpty)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (preview != null) ...[
            Text(
              all.isEmpty
                  ? '没有找到需要识别或改写的数字标题。'
                  : '找到 ${all.length} 个数字标题 · 新增章节 $added · 改写标题 $renamed',
              key: const ValueKey('numeric-summary'),
              style: ui(13, w: 600, c: d.ink),
            ),
            if (removed > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '另有 $removed 个现有标题会被移除，详见识别规则的全书差异；核对后再应用。',
                  style: ui(12, c: d.warn),
                ),
              ),
            const SizedBox(height: 8),
            if (all.length > 8)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: TextField(
                  controller: search,
                  style: ui(12.5, c: d.ink),
                  onChanged: (_) => setState(() {}),
                  decoration: deskInput(context, hint: '搜索标题或行号'),
                ),
              ),
            Expanded(
              child: DeskListBox(
                paper: false,
                child: ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => row(shown[i]),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('个别不是标题的行：在识别规则的“非标题词库”里排除后重新预览。', style: ui(11.5, c: d.ink3)),
          ],
        ],
      ),
    );
  }

  Widget row(Map c) {
    final d = context.desk;
    final added = c['kind'] == 'added';
    final before = numericOriginalLine(c);
    return Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text('${c['line']}', style: mono(11, c: d.ink3)),
          ),
          DeskTag(added ? '新增' : '改写', added ? Tone.ok : Tone.neutral),
          const SizedBox(width: 10),
          if (before.isNotEmpty && before != '${c['after']}') ...[
            Flexible(
              child: Text(
                before,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(12.5, c: d.ink3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.arrow_forward_rounded, size: 14, color: d.ink3),
            ),
          ],
          Flexible(
            flex: 2,
            child: Text(
              '${c['after']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(12.5, c: d.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// 原行文字：新增项取摘录里的标题行（摘录从上一行开始；第 1 行时从本行开始），改写项取原标题。
String numericOriginalLine(Map c) {
  if (c['kind'] != 'added') return '${c['before'] ?? ''}';
  final lines = '${c['excerpt'] ?? ''}'.split('\n');
  final at = ((c['line'] as num?) ?? 1) >= 2 ? 1 : 0;
  return at < lines.length ? lines[at].trim() : '';
}
