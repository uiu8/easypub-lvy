// 编辑清理规则（CLEAN-042–067）：左栏规则参数，右栏本书试算。试算只读，迟到的旧结果与过期结果都不显示；
// 采用只返回规则，正文仍须检测并确认后才改变。逻辑沿用 V4 前的 CleanupRuleDialog。
// 设计：design_review_v37/d3_cleanup.dart（D3-J 编辑清理规则）。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/cleanup_service.dart';
import '../controls/controls.dart' show DeskButton, DeskChoice;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

class CleanupRuleDialog extends StatefulWidget {
  const CleanupRuleDialog({
    super.key,
    this.initial,
    this.previewRule,
    this.isCurrent,
    this.changes,
    this.draft,
    this.onDraft,
    this.onDiscard,
  });
  final Map<String, dynamic>? initial;
  final Future<CleanupPreview> Function(Map<String, dynamic>)? previewRule;
  final bool Function(CleanupPreview)? isCurrent;
  final Listenable? changes;
  final Map<String, dynamic>? draft;
  final ValueChanged<Map<String, dynamic>>? onDraft;
  final VoidCallback? onDiscard;
  @override
  State<CleanupRuleDialog> createState() => _CleanupRuleDialogState();
}

class _CleanupRuleDialogState extends State<CleanupRuleDialog> {
  late final base = widget.initial == null
      ? <String, dynamic>{}
      : cleanupBase(widget.initial!);
  late String kind = base['kind'] as String? ?? 'trim_trailing_spaces';
  late String scope = widget.initial?['scope'] as String? ?? 'all';
  late String mode = base['mode'] as String? ?? 'chinese';
  late String direction = base['direction'] as String? ?? 't2s';
  late String numberStyle = base['style'] as String? ?? 'chinese';
  late bool bareTitles = base['bare_titles'] == true;
  late final options = (base['options'] as Map? ?? {}).cast<String, dynamic>();
  late bool defaults = options['include_defaults'] as bool? ?? true;
  late bool headers = options['include_headers'] as bool? ?? true;
  late bool ignoreCase = options['ignore_case'] as bool? ?? true;
  late bool patternRegex = options['pattern']?['regex'] == true;
  late bool preserveRegex = options['preserve_pattern']?['regex'] == true;
  late final pattern = TextEditingController(
    text: options['pattern']?['text'] as String? ?? '',
  );
  late final preserve = TextEditingController(
    text: options['preserve_pattern']?['text'] as String? ?? '',
  );
  late final keywords = TextEditingController(
    text: (options['keywords'] as List? ?? []).join('\n'),
  );
  late final keepWords = TextEditingController(
    text: (options['preserve_keywords'] as List? ?? []).join('\n'),
  );
  static const marks = {
    'marks': '中文语境标点',
    'ellipsis': '省略号',
    'dashes': '破折号',
    'quotes': '成对重复弯引号',
  };
  late final punctuation = {
    for (final key in marks.keys) key: options[key] as bool? ?? true,
  };
  late final find = TextEditingController(
    text: base['find'] as String? ?? base['pattern'] as String? ?? '',
  );
  late final replace = TextEditingController(
    text: base['replace'] as String? ?? '',
  );
  late final minimum = TextEditingController(
    text: '${base['min_chars'] ?? 12}',
  );
  late final name = TextEditingController(
    text: widget.initial == null
        ? cleanupLabels[kind] ?? kind
        : cleanupLabel(widget.initial!),
  );
  String error = '';
  CleanupPreview? sample;
  bool sampling = false;
  int ticket = 0;
  @override
  void initState() {
    super.initState();
    final restored = widget.draft;
    if (restored != null) {
      kind = restored['kind'] as String;
      scope = restored['scope'] as String;
      mode = restored['mode'] as String;
      direction = restored['direction'] as String;
      numberStyle = restored['numberStyle'] as String;
      bareTitles = restored['bareTitles'] == true;
      defaults = restored['defaults'] == true;
      headers = restored['headers'] == true;
      ignoreCase = restored['ignoreCase'] == true;
      patternRegex = restored['patternRegex'] == true;
      preserveRegex = restored['preserveRegex'] == true;
      punctuation.addAll((restored['punctuation'] as Map).cast<String, bool>());
      for (final entry in fields.entries) {
        entry.value.text = restored[entry.key] as String;
      }
    }
    widget.changes?.addListener(refresh);
    for (final controller in [
      name,
      find,
      replace,
      minimum,
      pattern,
      preserve,
      keywords,
      keepWords,
    ]) {
      controller.addListener(invalidateSample);
    }
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  void edit(VoidCallback update) {
    ticket++;
    setState(() {
      update();
      sample = null;
      sampling = false;
      error = '';
    });
    widget.onDraft?.call({
      'kind': kind,
      'scope': scope,
      'mode': mode,
      'direction': direction,
      'numberStyle': numberStyle,
      'bareTitles': bareTitles,
      'defaults': defaults,
      'headers': headers,
      'ignoreCase': ignoreCase,
      'patternRegex': patternRegex,
      'preserveRegex': preserveRegex,
      'punctuation': punctuation,
      for (final entry in fields.entries) entry.key: entry.value.text,
    });
  }

  Map<String, TextEditingController> get fields => {
    'name': name,
    'find': find,
    'replace': replace,
    'minimum': minimum,
    'pattern': pattern,
    'preserve': preserve,
    'keywords': keywords,
    'keepWords': keepWords,
  };

  void invalidateSample() => edit(() {});
  Future<void> preview() async {
    final rule = value();
    if (rule == null) return;
    final generation = ++ticket;
    setState(() {
      sampling = true;
      sample = null;
      error = '';
    });
    try {
      final next = await widget.previewRule!(rule);
      if (mounted && generation == ticket) setState(() => sample = next);
    } catch (e) {
      if (mounted && generation == ticket) {
        setState(
          () => error = deskErrorText(e, '试算失败，请核对规则语法、保留条件和已有章节编辑。原设置未改变。'),
        );
      }
    } finally {
      if (mounted && generation == ticket) setState(() => sampling = false);
    }
  }

  static const editable = [
    'trim_trailing_spaces',
    'collapse_blank_lines',
    'remove_ad_lines',
    'remove_duplicate_titles',
    'normalize_width',
    'normalize_punctuation',
    'remove_invisible',
    'ocr_han_spaces',
    'ocr_ellipsis',
    'join_hard_wraps',
    'literal_replace',
    'regex_replace',
    'multiline_regex_replace',
    'chinese_variant',
    'chapter_numbers',
    'chinese_punctuation',
    'notice_lines',
  ];
  List<String> get scopes => ['remove_ad_lines', 'notice_lines'].contains(kind)
      ? ['all']
      : kind == 'remove_duplicate_titles'
      ? ['all', 'headings']
      : ['join_hard_wraps', 'multiline_regex_replace'].contains(kind)
      ? ['all', 'body']
      : ['all', 'body', 'headings'];
  @override
  void dispose() {
    ticket++;
    widget.changes?.removeListener(refresh);
    name.dispose();
    find.dispose();
    replace.dispose();
    minimum.dispose();
    pattern.dispose();
    preserve.dispose();
    keywords.dispose();
    keepWords.dispose();
    super.dispose();
  }

  void submit() {
    final rule = value();
    if (rule != null) Navigator.pop(context, rule);
  }

  Map<String, dynamic>? value() {
    if (name.text.trim().isEmpty ||
        utf8.encode(name.text.trim()).length > 256 ||
        name.text.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'))) {
      setState(() => error = '名称不能为空，最多 256 UTF-8 字节，不能含控制字符。');
      return null;
    }
    final words = keywords.text
        .split(RegExp(r'\r\n|\r|\n'))
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
    final keeps = keepWords.text
        .split(RegExp(r'\r\n|\r|\n'))
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
    if (kind == 'notice_lines' &&
        ([words, keeps].any(
              (v) =>
                  v.length > 64 ||
                  v.any(
                    (s) => utf8.encode(s).length > 256 || s.contains('\u0000'),
                  ),
            ) ||
            [pattern.text, preserve.text].any(
              (v) =>
                  utf8.encode(v).length > 4096 ||
                  v.contains(RegExp('[\u0000\r\n]')),
            ))) {
      setState(
        () =>
            error = '每组最多 64 个关键词，每个最多 256 UTF-8 字节；匹配条件最多 4096 字节，不能含换行或空字符。',
      );
      return null;
    }
    if (kind.contains('replace') && find.text.isEmpty) {
      setState(() => error = '匹配内容不能为空。');
      return null;
    }
    final min = int.tryParse(minimum.text);
    if (kind == 'join_hard_wraps' && (min == null || min < 1 || min > 4096)) {
      setState(() => error = '前行最少字符数须为 1–4096。');
      return null;
    }
    final rule = <String, dynamic>{
      if (kind == base['kind']) ...base,
      'kind': kind,
      if (kind.contains('replace')) ...{
        if (kind == 'literal_replace')
          'find': find.text
        else
          'pattern': find.text,
        'replace': replace.text,
      },
      if (kind == 'join_hard_wraps') ...{'mode': mode, 'min_chars': min},
      if (kind == 'chinese_variant') ...{
        'direction': direction,
        'dictionary_version': 'ferrous-opencc-0.4.0',
      },
      if (kind == 'chapter_numbers') ...{
        'style': numberStyle,
        'bare_titles': bareTitles,
      },
      if (kind == 'chinese_punctuation') 'options': punctuation,
      if (kind == 'notice_lines')
        'options': {
          'include_defaults': defaults,
          'include_headers': headers,
          'ignore_case': ignoreCase,
          'keywords': words,
          'preserve_keywords': keeps,
          'pattern': pattern.text.isEmpty
              ? null
              : {'text': pattern.text, 'regex': patternRegex},
          'preserve_pattern': preserve.text.isEmpty
              ? null
              : {'text': preserve.text, 'regex': preserveRegex},
        },
    };
    return <String, dynamic>{
      if (widget.initial?['kind'] == 'configured') ...widget.initial!,
      'kind': 'configured',
      'enabled': widget.initial?['enabled'] ?? true,
      'name': name.text.trim(),
      'scope': scope,
      'rule': rule,
    };
  }

  // ---------------------------------------------------------------- 视图

  Widget text(
    TextEditingController c,
    String label, {
    int lines = 1,
    bool code = false,
    Key? key,
  }) {
    final d = context.desk;
    return TextField(
      key: key,
      controller: c,
      minLines: 1,
      maxLines: lines,
      style: code ? mono(12.5, c: d.ink) : ui(13, c: d.ink),
      decoration: deskInput(context).copyWith(labelText: label),
    );
  }

  Widget choice(
    String label,
    String value,
    Map<String, String> items,
    ValueChanged<String> onChanged, {
    Key? key,
  }) {
    final d = context.desk;
    // R4-10：编辑台的选择框（原为 Material 下拉）。
    return DeskChoice<String>(
      key: key,
      initialValue: value,
      isExpanded: true,
      decoration: deskInput(context).copyWith(labelText: label),
      items: [
        for (final e in items.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, style: ui(13, c: d.ink)),
          ),
      ],
      onChanged: (v) {
        if (v != null) edit(() => onChanged(v));
      },
    );
  }

  Widget option(String label, bool value, ValueChanged<bool> change) {
    final d = context.desk;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => edit(() => change(!value)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(value: value, onChanged: (v) => edit(() => change(v!))),
          Text(label, style: ui(12.5, c: d.ink)),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget note(String t) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(t, style: ui(11.5, c: context.desk.ink3, h: 1.5)),
  );

  List<Widget> parameters() => [
    if (kind.contains('replace')) ...[
      text(find, '匹配文字或正则', lines: 3, code: kind != 'literal_replace'),
      const SizedBox(height: 10),
      text(replace, '替换为（可为空）', lines: 3),
    ],
    if (kind == 'join_hard_wraps') ...[
      choice('合并方式', mode, const {
        'chinese': '中文连续',
        'space': '单词间加空格',
      }, (v) => mode = v),
      const SizedBox(height: 10),
      text(minimum, '前行最少字符数'),
    ],
    if (kind == 'chinese_variant')
      choice('转换方向', direction, const {
        't2s': '繁体 → 简体',
        's2t': '简体 → 繁体',
      }, (v) => direction = v),
    if (kind == 'chapter_numbers') ...[
      choice('编号样式', numberStyle, const {
        'chinese': '中文数字：第一百零二章',
        'arabic': '阿拉伯数字：第102章',
      }, (v) => numberStyle = v),
      const SizedBox(height: 6),
      option('同时识别数字开头的标题', bareTitles, (v) {
        bareTitles = v;
        if (v) scope = 'all';
      }),
      note('只改变编号写法，不补号、不重排。数字开头也可能是正文，请核对差异；启用时范围恢复为全文。'),
    ],
    if (kind == 'chinese_punctuation') ...[
      Wrap(
        children: [
          for (final e in marks.entries)
            option(e.value, punctuation[e.key]!, (v) => punctuation[e.key] = v),
        ],
      ),
      note('保护网址、邮箱、行内代码和数字标点。仅在中文邻近语境处理，不自动改写纯英文句点或直引号。'),
    ],
    if (kind == 'notice_lines') ...[
      Wrap(
        children: [
          option('常见广告与章末提示', defaults, (v) => defaults = v),
          option('独立页码与页眉', headers, (v) => headers = v),
          option('忽略大小写', ignoreCase, (v) => ignoreCase = v),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: text(keywords, '候选关键词（每行一个）', lines: 4)),
          const SizedBox(width: 10),
          Expanded(child: text(keepWords, '优先保留关键词（每行一个）', lines: 4)),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(child: text(pattern, '候选匹配条件（可为空）', code: patternRegex)),
          option('候选条件使用正则', patternRegex, (v) => patternRegex = v),
        ],
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(child: text(preserve, '优先保留条件（可为空）', code: preserveRegex)),
          option('保留条件使用正则', preserveRegex, (v) => preserveRegex = v),
        ],
      ),
      note('命中只列候选。保留条件优先，标题与受保护源行不可排除；正则语法在 Rust 检测时验证。'),
    ],
  ];

  Widget trial() {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: d.sunken,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('本书规则试算', style: ui(13, w: 650, c: d.ink)),
              ),
              DeskButton(
                '试算本书',
                icon: Icons.play_arrow_rounded,
                onPressed: sampling ? null : preview,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (sampling)
            const LinearProgressIndicator(minHeight: 2)
          else if (sample == null)
            Text('查看这条规则会如何改变本书，试算不会修改正文。', style: ui(11.5, c: d.ink3))
          else if (!(widget.isCurrent?.call(sample!) ?? false))
            Text('书稿已变化，试算结果过期，请重新试算。', style: ui(12, c: d.ink2))
          else ...[
            Text(
              '整套规则：${sample!.total} 处变更 · ${sample!.candidateTotal} 条提示候选',
              style: ui(12, w: 600, c: d.ink),
            ),
            const SizedBox(height: 10),
            if (sample!.actions.isNotEmpty) ...[
              Text(
                '首处差异 · 原稿第 ${sample!.actions.first.line} 行${sample!.actions.first.truncated ? ' · 节选' : ''}',
                style: ui(11.5, c: d.ink3),
              ),
              const SizedBox(height: 6),
              sampleDifference(sample!.actions.first),
            ] else
              Text('当前范围内没有文字变更。提示候选仍须逐项审阅。', style: ui(12, c: d.ink2)),
            if (sample!.candidates.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '提示候选 · 第 ${sample!.candidates.first.line} 行：${sample!.candidates.first.text}',
                  style: ui(12, c: d.ink2),
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final wide =
        MediaQuery.sizeOf(context).width >= 1000 && widget.previewRule != null;
    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        text(name, '名称', key: const ValueKey('cleanup-rule-name')),
        const SizedBox(height: 12),
        choice(
          '规则类型',
          kind,
          {
            for (final v in {...editable, kind}) v: cleanupLabels[v] ?? v,
          },
          (v) {
            kind = v;
            error = '';
            if (!scopes.contains(scope)) scope = scopes.first;
          },
        ),
        const SizedBox(height: 12),
        const DeskLabel('作用范围'),
        Align(
          alignment: Alignment.centerLeft,
          child: KeyedSubtree(
            key: ValueKey('$kind-$scope'),
            child: DeskSegmented<String>(
              value: scope,
              options: {
                for (final v in scopes)
                  v: {'all': '全文', 'body': '仅正文', 'headings': '仅标题'}[v]!,
              },
              onChanged: (v) => edit(() => scope = v),
            ),
          ),
        ),
        if (scopes.length == 1) note('此类规则只能作用于全文。'),
        const SizedBox(height: 14),
        ...parameters(),
      ],
    );
    return DeskDialog(
      title: '编辑清理规则',
      subtitle: '采用规则后可预览清理结果；只有确认采用清理方案才会修改编辑稿。',
      closeTooltip: '取消',
      width: wide ? 1000 : 680,
      onClose: () {
        widget.onDiscard?.call();
        Navigator.pop(context);
      },
      footerLeft: error.isEmpty ? null : Text(error, style: ui(12, c: d.pen)),
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () {
            widget.onDiscard?.call();
            Navigator.pop(context);
          },
        ),
        DeskButton(
          '采用此规则',
          key: const ValueKey('cleanup-rule-accept'),
          primary: true,
          onPressed: submit,
        ),
      ],
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 460, child: form),
                const SizedBox(width: 18),
                Expanded(child: trial()),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                form,
                if (widget.previewRule != null) ...[
                  const SizedBox(height: 16),
                  trial(),
                ],
              ],
            ),
    );
  }

  Widget sampleDifference(CleanupChange change) {
    final d = context.desk;
    final before = change.before.runes.toList();
    final after = (change.after ?? '').runes.toList();
    var prefix = 0;
    while (prefix < before.length &&
        prefix < after.length &&
        before[prefix] == after[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < before.length - prefix &&
        suffix < after.length - prefix &&
        before[before.length - suffix - 1] ==
            after[after.length - suffix - 1]) {
      suffix++;
    }
    Widget pane(
      String label,
      List<int> text,
      Color fg,
      Color highlight,
      String empty,
    ) => Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: d.paper,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: ui(11, w: 620, c: fg)),
          const SizedBox(height: 4),
          if (text.isEmpty)
            Text(empty, style: ui(12.5, c: d.ink3))
          else
            SelectableText.rich(
              TextSpan(
                style: serif(13.5, c: d.ink, h: 1.6),
                children: [
                  TextSpan(text: String.fromCharCodes(text.take(prefix))),
                  TextSpan(
                    text: String.fromCharCodes(
                      text.sublist(prefix, text.length - suffix),
                    ),
                    style: TextStyle(backgroundColor: highlight),
                  ),
                  TextSpan(
                    text: String.fromCharCodes(text.skip(text.length - suffix)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        pane('修改前', before, d.del, d.delSoft, '（空行）'),
        const SizedBox(height: 6),
        pane(
          '修改后',
          after,
          d.add,
          d.addSoft,
          change.after == null ? '（删除此行）' : '（空行）',
        ),
      ],
    );
  }
}
