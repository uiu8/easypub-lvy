// 识别规则面板（CH-102–133）：左栏规则字段（正则着色、命名组、不支持写法就地提示、预设），
// 右栏单行试匹配记录与全书差异预览。试匹配与全书差异都由 Rust 识别器生成，只读；
// 应用必须先预览并勾选核对，作为一批写入、可整批撤销。设计：design_review_v37/rules.dart（D2-F）。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/chapter_rules_service.dart';
import '../controls/controls.dart' show DeskButton, DeskChoice;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

Future<void> showChapterRulesDialog(
  BuildContext context, {
  required ChapterRulesService service,
  String? bookId,
  String? appendNonHeading,
}) => showDialog<void>(
  context: context,
  builder: (_) => _RulesSheet(
    session: service.openRules(bookId),
    appendNonHeading: appendNonHeading,
  ),
);

/// 内置的三套常用预设（CH-250）：只覆盖下列字段，其余沿用内置默认；不能改名或删除。
/// 填写常规标题正则后内置识别整体停用，所以“第X话”“英文”两套同时给出卷级表达式。
const commonRulePresets = <String, Map<String, Object>>{
  '常用：第X话 / 第X集': {
    'chapter_pattern': r'^\s*第\s*(?<number>[0-9０-９零〇一二两兩三四五六七八九十百千万萬]+)\s*[话話集章回](?:\s*[:：、]?\s*(?<title>\S.*?))?\s*$',
    'volume_pattern': r'^\s*第\s*(?<number>[0-9０-９零〇一二两兩三四五六七八九十百千万萬]+)\s*[卷部](?:\s*[:：、]?\s*(?<title>\S.*?))?\s*$',
  },
  '常用：纯数字标题': {'numeric': true},
  '常用：英文 Chapter N': {
    'chapter_pattern': r'^\s*(?i:chapter)\s+(?<number>\d+)(?:\s*[:.：\-—]?\s*(?<title>\S.*?))?\s*$',
    'volume_pattern': r'^\s*(?i:volume|part|book)\s+(?<number>\d+)(?:\s*[:.：\-—]?\s*(?<title>\S.*?))?\s*$',
  },
};

const _helpLevels =
    '开启“按卷、章、节识别层级”后，可分别为卷、章、节填写正则；留空的一项使用内置规则。'
    '注意：一旦填写了“常规标题正则”，内置识别整体停用，留空的卷、章、节也不再识别。\n'
    '写法：用 (?<number>…) 标出编号，(?<title>…) 标出标题；不写 title 组时整行作标题。'
    r'识别器不支持环视 (?=…) 和反向引用 \1。'
    '\n'
    r'例：^第(?<number>\d+)话\s*(?<title>.+)$';
const _helpCorrections =
    '用途：相邻两章的编号相差 2（中间缺了一章）时，检查这两章之间有没有一行像“第一百一十久章 标题”'
    '这样只因一个错字而没被识别的标题。按本表把错字换掉后正好等于缺的编号，就在检查结果中列为'
    '“章节编号疑误”，给出修复建议；不会自动改正文。平常识别标题不用这张表。\n'
    '格式：每行一条“原字=数字”，例如 久=九。两边各一个字；原字本身不能是数字；目标必须是数字'
    '（如 九、9）；同一原字只写一次；最多 2048 字节；留空即关闭。\n'
    '添加：展开后另起一行写上新的一条，再试匹配、预览并应用本书规则后生效。';
const _helpPhrases =
    '非标题词库：每行一条。这一行只要包含其中的文字，就永远不算标题——识别时排除，检查不再报“漏识别的标题”，'
    '修复方案也不会提议；已经被收入目录的会列为“正文被当成标题”，可以还原为正文。例如：两章合一章、求月票。\n'
    '标题词库：每行一条。包含其中文字的行按章节识别，比如没有编号的“楔子”“引子”。两个词库都写了同一行时，以非标题词库为准。\n'
    '以 re: 开头的一条按正则匹配，例如 re:^\\d+\\.请（不支持环视和反向引用）。改动后仍需试匹配、核对全书差异再应用。';
const _helpExceptions =
    '只在这本书的规则里生效，三项都留空时规则不变。\n'
    '允许重复的标题：每行一条，例如“上架感言”“番外”。相邻两章标题相同、中间只有空行时，'
    '命中的标题不再报“连续重复标题”，修复方案也不提议移除。以 re: 开头的一条按正则匹配。\n'
    '允许的编号跳跃：填写跳过的章号，例如 9 或 101-104，用逗号、顿号、空格或换行分隔。'
    '只有跳过的章号全部在列表里时才不报“章节编号跳跃”。\n'
    '标题后缀清理：每行一条，例如（求月票）。标题以它结尾时去掉，只改标题，不动正文；'
    '以 re: 开头的一条按正则匹配到标题末尾。去掉后标题为空时保留原标题。\n'
    '“全书试匹配与差异”会列出被清理的标题，并在顶部写出两项检查数量的变化；应用后可在检查页复查。';
const _helpPresets =
    '把当前整套规则（各项正则、层级开关、数字标题设置、错字表）存成一个名字，以后在任何书中载入。'
    '载入只会填入左栏，仍需试匹配、核对全书差异后再应用。\n'
    '“常用：”开头的三套是内置预设，不能改名或删除。同名保存会覆盖；最多 64 个。';

/// 识别规则的三种例外（V17，CH-258–260）；留空时不计入规则标识。
const _exceptionFields = [
  'allowed_duplicate_titles',
  'allowed_number_gaps',
  'title_suffixes',
];

const _regexFields = {
  'chapter_pattern',
  'volume_pattern',
  'level_chapter_pattern',
  'section_pattern',
  'numeric_pattern',
};

/// 正则着色：命名组 number 赭、title 苔，其余组名次墨加粗；语法符号浅墨；
/// 识别器不支持的环视与反向引用用朱色波浪线标出。只改显示，不改文字。
class _RegexController extends TextEditingController {
  _RegexController(this.desk);
  Desk desk;

  static final _token = RegExp(
    r'\(\?<[=!]|\(\?[=!]|\\[1-9]|\(\?<([A-Za-z_][A-Za-z0-9_]*)>|\\.|[\^$()\[\]{}|*+?.]',
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final d = desk;
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final t = m[0]!;
      final group = m[1];
      if (t.startsWith('(?<=') ||
          t.startsWith('(?<!') ||
          t.startsWith('(?=') ||
          t.startsWith('(?!') ||
          RegExp(r'^\\[1-9]$').hasMatch(t)) {
        spans.add(
          TextSpan(
            text: t,
            style: TextStyle(
              color: d.pen,
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.wavy,
              decorationColor: d.pen,
            ),
          ),
        );
      } else if (group != null) {
        final (fg, bg) = switch (group) {
          'number' => d.tone(Tone.warn),
          'title' => d.tone(Tone.ok),
          _ => (d.ink2, Colors.transparent),
        };
        spans
          ..add(
            TextSpan(
              text: '(?<',
              style: TextStyle(color: d.ink3),
            ),
          )
          ..add(
            TextSpan(
              text: group,
              style: TextStyle(
                color: fg,
                backgroundColor: bg,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
          ..add(
            TextSpan(
              text: '>',
              style: TextStyle(color: d.ink3),
            ),
          );
      } else if (t.startsWith(r'\')) {
        spans.add(
          TextSpan(
            text: t,
            style: TextStyle(color: d.ink2),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: t,
            style: TextStyle(color: d.ink3),
          ),
        );
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: style, children: spans);
  }

  /// 命名组名称（按出现顺序去重）。
  List<String> get groups => [
    ...{
      for (final m in RegExp(
        r'\(\?<([A-Za-z_][A-Za-z0-9_]*)>',
      ).allMatches(text))
        m[1]!,
    },
  ];

  bool get unsupported => RegExp(r'\(\?<[=!]|\(\?[=!]|\\[1-9]').hasMatch(text);
}

class _RulesSheet extends StatefulWidget {
  const _RulesSheet({required this.session, this.appendNonHeading});
  final ChapterRulesSession session;

  /// 从问题审阅“加入非标题词库”进入：打开后把这一条加入词库（仍是未应用草稿）。
  final String? appendNonHeading;
  @override
  State<_RulesSheet> createState() => _RulesSheetState();
}

class _Trial {
  const _Trial(this.text, this.result, this.matched);
  final String text, result;
  final bool matched;
}

class _RulesSheetState extends State<_RulesSheet> {
  late final fields = <String, TextEditingController>{
    for (final key in [
      'chapter_pattern',
      'volume_pattern',
      'level_chapter_pattern',
      'section_pattern',
      'numeric_pattern',
      'number_corrections',
      'numeric_minimum_body_lines',
      'non_heading',
      'force_heading',
      ..._exceptionFields,
    ])
      key: _regexFields.contains(key)
          ? _RegexController(Desk.light)
          : TextEditingController(),
  };
  final sample = TextEditingController(text: '第12话 风起');
  final presetName = TextEditingController();
  final search = TextEditingController();
  Map<String, dynamic>? rules, defaults;
  List<Map<String, dynamic>> presets = [];
  String? selectedPreset;

  /// 最近载入的预设名；用户改动后来源变为本书规则，不再显示。
  String? activePreset;
  String message = '';
  bool busy = false, preserve = true, confirmed = false, showMatches = false;
  bool failed = false;
  bool advancedOpen = false, correctionsOpen = false, presetsOpen = false;
  bool phrasesOpen = false, exceptionsOpen = false;
  final trials = <_Trial>[];
  int generation = 0;
  ChapterRulesPreview? preview;

  /// 内置规则说明（CH-248）；读取失败时不显示入口。
  Map<String, dynamic>? builtinInfo;

  /// 已应用规则的标识：对可编辑字段内容取摘要，用来分辨检查结果对应哪一套规则。
  String? appliedFingerprint;

  String fingerprintOf(Map<String, dynamic> values) {
    final keys = fields.keys.toList()..sort();
    final normalized = {
      for (final k in keys)
        // 例外留空时不计入，已有规则的标识不变。
        if (!_exceptionFields.contains(k) || '${values[k] ?? ''}'.isNotEmpty)
          k: '${values[k] ?? ''}',
    };
    return sha1
        .convert(utf8.encode(jsonEncode(normalized)))
        .toString()
        .substring(0, 6);
  }

  String editingFingerprint() =>
      fingerprintOf({for (final e in fields.entries) e.key: e.value.text});

  @override
  void initState() {
    super.initState();
    run(() async {
      final data = await widget.session.load();
      if (!mounted) return;
      defaults = Map<String, dynamic>.from(data['defaults'] as Map);
      presets = (data['presets'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      appliedFingerprint = fingerprintOf(
        Map<String, dynamic>.from(data['rules'] as Map),
      );
      final draft = data['draft'] as Map?;
      loadRules(
        Map<String, dynamic>.from(
          draft?['rules'] as Map? ?? data['rules'] as Map,
        ),
      );
      preserve = draft?['preserve_decisions'] != false;
      advancedOpen = [
        'volume_pattern',
        'level_chapter_pattern',
        'section_pattern',
      ].any((k) => fields[k]!.text.isNotEmpty);
      correctionsOpen = fields['number_corrections']!.text.isNotEmpty;
      phrasesOpen = [
        'non_heading',
        'force_heading',
      ].any((k) => fields[k]!.text.isNotEmpty);
      exceptionsOpen = _exceptionFields.any((k) => fields[k]!.text.isNotEmpty);
      final phrase = widget.appendNonHeading?.trim();
      if (phrase != null && phrase.isNotEmpty) {
        final list = fields['non_heading']!;
        final lines = list.text.split('\n').map((v) => v.trim()).toSet();
        if (!lines.contains(phrase)) {
          list.text = [
            if (list.text.trim().isNotEmpty) list.text.trimRight(),
            phrase,
          ].join('\n');
          changed();
        }
        phrasesOpen = true;
        message = '已把“$phrase”加入非标题词库（未应用）。请先“全书试匹配与差异”核对，再应用本书规则。';
      }
      if (draft != null) message = '已恢复未应用规则；需要重新预览后采用。';
    });
    widget.session
        .builtinDescription()
        .then((value) {
          if (mounted) setState(() => builtinInfo = value);
        })
        .catchError((_) {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final c in fields.values) {
      if (c is _RegexController) c.desk = context.desk;
    }
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    sample.dispose();
    presetName.dispose();
    search.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 逻辑（与 V3 前逐行对应）

  Future<void> run(Future<void> Function() task) async {
    if (busy) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      await task();
    } catch (error) {
      if (mounted) {
        failed = true;
        message = deskErrorText(error, '操作没有完成。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void loadRules(Map<String, dynamic> next) {
    rules = Map<String, dynamic>.from(next);
    for (final entry in fields.entries) {
      entry.value.text = '${rules![entry.key] ?? ''}';
    }
    preview = null;
    confirmed = false;
    generation++;
  }

  Map<String, dynamic> current() {
    final next = Map<String, dynamic>.from(rules!);
    for (final entry in fields.entries) {
      next[entry.key] = entry.value.text;
    }
    final minimum = int.tryParse(fields['numeric_minimum_body_lines']!.text);
    if (minimum == null || minimum < 0 || minimum > 1000) {
      throw const FormatException('正文行数请填写0至1000的整数。');
    }
    next['numeric_minimum_body_lines'] = minimum;
    return next;
  }

  void changed() {
    setState(() {
      preview = null;
      confirmed = false;
      generation++;
      message = '';
      rules!['origin'] = widget.session.hasBook ? 'book' : 'import_default';
    });
    // The workspace already debounces disk writes. Store every input immediately
    // so closing with Escape cannot discard the last characters.
    saveDraft();
  }

  void saveDraft() {
    if (rules == null) return;
    final value = Map<String, dynamic>.from(rules!);
    for (final entry in fields.entries) {
      value[entry.key] = entry.key == 'numeric_minimum_body_lines'
          ? int.tryParse(entry.value.text) ?? entry.value.text
          : entry.value.text;
    }
    widget.session.saveDraft({'rules': value, 'preserve_decisions': preserve});
  }

  Future<void> makePreview() async {
    final ticket = generation;
    final result = await widget.session.preview(
      current(),
      preserveDecisions: preserve,
    );
    if (!mounted || ticket != generation) return;
    preview = result;
    confirmed = false;
    message = '预览完成。新增、移除和层级变化会替换当前结构；正文保留，可整批撤销。';
  }

  Future<void> trySample() async {
    final text = sample.text;
    final r = await widget.session.sample(current(), text);
    final m = r['match'] as Map?;
    final result = m == null
        ? '不匹配当前规则。'
        : '匹配：${{'chapter': '章', 'volume': '卷', 'section': '节'}[m['role']] ?? m['role']} · 编号 ${m['number'] ?? '无'} · ${m['title']}';
    trials.insert(0, _Trial(text, result, m != null));
    if (trials.length > 8) trials.removeLast();
  }

  Future<void> savePreset({bool rename = false}) async {
    final name = presetName.text.trim();
    if (name.isEmpty) throw const FormatException('请填写预设名称。');
    final next = [for (final item in presets) Map<String, dynamic>.from(item)];
    final existing = next.indexWhere((p) => p['name'] == name);
    if (rename) {
      if (selectedPreset == null) throw const FormatException('请先选择要重命名的预设。');
      if (existing >= 0 && name != selectedPreset) {
        throw const FormatException('此名称已存在，请使用另一名称。');
      }
      next.firstWhere((p) => p['name'] == selectedPreset)['name'] = name;
    } else if (existing >= 0) {
      next[existing] = {'name': name, 'rules': current()};
    } else {
      next.add({'name': name, 'rules': current()});
    }
    await widget.session.savePresets(next);
    presets = next;
    selectedPreset = name;
    message = rename ? '预设已重命名。' : '预设已保存。';
  }

  Future<void> deletePreset() async {
    final next = presets.where((p) => p['name'] != selectedPreset).toList();
    await widget.session.savePresets(next);
    presets = next;
    selectedPreset = null;
    message = '预设已删除，当前规则保留。';
  }

  void loadPreset(String name) {
    final common = commonRulePresets[name];
    if (common != null) {
      run(() async {
        final base = await widget.session.builtin();
        if (!mounted) return;
        setState(() {
          selectedPreset = name;
          presetName.text = '';
          activePreset = name;
          loadRules({...base, ...common, 'origin': 'preset'});
          message = '已载入“$name”；试匹配并核对全书差异后再应用。';
        });
        saveDraft();
      });
      return;
    }
    setState(() {
      selectedPreset = name;
      presetName.text = name;
      activePreset = name;
      loadRules({
        ...Map<String, dynamic>.from(
          presets.firstWhere((p) => p['name'] == name)['rules'] as Map,
        ),
        'origin': 'preset',
      });
    });
    saveDraft();
  }

  /// 以内置规则为起点（CH-249）：把参考正则填入输入框，仍是未应用草稿。
  void seedFromBuiltin(String key, String pattern) {
    if (key == 'numeric_pattern') rules!['numeric'] = true;
    fields[key]!.text = pattern;
    changed();
    setState(
      () => message = key == 'chapter_pattern'
          ? '已填入内置规则的参考正则。改用自定义规则后，内置的正文排除（作者说明、“回头”等）不再生效；请先试匹配并核对全书差异。'
          : r'已填入内置数字标题正则；原样保留时仍按内置执行，修改后需去掉其中的 (?!\d) 环视。',
    );
  }

  Future<void> showBuiltin(String kind) async {
    final info = builtinInfo;
    if (info == null) return;
    final pattern = await showDialog<String>(
      context: context,
      builder: (_) => _BuiltinRuleDialog(
        info: Map<String, dynamic>.from(info[kind] as Map),
        numeric: kind == 'numeric',
      ),
    );
    if (!mounted || pattern == null) return;
    seedFromBuiltin(
      kind == 'numeric' ? 'numeric_pattern' : 'chapter_pattern',
      pattern,
    );
  }

  Future<void> saveDefault() async {
    await widget.session.saveDefault({
      ...current(),
      'origin': 'import_default',
    });
    defaults = current();
    message = '已保存为以后导入默认；现有章节树保持原状。';
  }

  // ---------------------------------------------------------------- 左栏：规则字段

  String get originLabel => switch (rules!['origin']) {
    'import_default' => '导入默认快照',
    'book' => '本书规则',
    'preset' => activePreset == null ? '规则预设' : '规则预设“$activePreset”',
    'legacy' => '历史识别结果；新规则应用前需预览',
    _ => '内置规则',
  };

  Widget label(String text, {String? hint, Widget? trailing, String? help}) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(text, style: ui(12.5, w: 620, c: d.ink)),
          if (help != null) DeskHelp(help),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                hint,
                overflow: TextOverflow.ellipsis,
                style: ui(11.5, c: d.ink3),
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }

  Widget input(String key, {String? hint, int lines = 1}) {
    final d = context.desk;
    final regex = fields[key] is _RegexController;
    return TextField(
      key: ValueKey('rules-$key'),
      controller: fields[key],
      enabled: !busy,
      minLines: 1,
      maxLines: lines,
      style: regex ? mono(12.5, c: d.ink) : ui(13, c: d.ink),
      onChanged: (_) => changed(),
      decoration: deskInput(context, hint: hint),
    );
  }

  /// 正则字段下方：命名组标签，或不支持写法的就地提示。
  Widget regexNote(String key) {
    final d = context.desk;
    final c = fields[key] as _RegexController;
    if (c.text.isEmpty) return const SizedBox(height: 4);
    if (c.unsupported) {
      return Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 15, color: d.pen),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '识别器不支持环视 (?=…)/(?<=…) 和反向引用 \\1；试匹配、预览和应用会被拒绝，请改写。',
                style: ui(11.5, c: d.pen, h: 1.45),
              ),
            ),
          ],
        ),
      );
    }
    final groups = c.groups;
    if (groups.isEmpty) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final g in groups)
            DeskTag(g, switch (g) {
              'number' => Tone.warn,
              'title' => Tone.ok,
              _ => Tone.neutral,
            }),
          Text(
            groups.contains('title')
                ? '命名组：number 为编号，title 为标题'
                : '未写 title 组时整行作标题',
            style: ui(11.5, c: d.ink3),
          ),
        ],
      ),
    );
  }

  Widget fold(String text, bool open, VoidCallback onTap, {String? help}) {
    final d = context.desk;
    return Row(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  open
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 18,
                  color: d.ink2,
                ),
                const SizedBox(width: 4),
                Text(text, style: ui(12.5, w: 620, c: d.ink)),
              ],
            ),
          ),
        ),
        if (help != null) DeskHelp(help, key: ValueKey('rules-help-$text')),
      ],
    );
  }

  Widget switchRow(String key, String text) => label(
    text,
    trailing: Switch(
      key: ValueKey('rules-$key'),
      value: rules![key] == true,
      onChanged: busy
          ? null
          : (v) {
              rules![key] = v;
              changed();
            },
    ),
  );

  Widget checkRow(
    String text,
    bool value,
    ValueChanged<bool>? onChanged, {
    Key? key,
  }) {
    final d = context.desk;
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Row(
        children: [
          Checkbox(
            key: key,
            value: value,
            onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
          ),
          Expanded(
            child: Text(text, style: ui(12.5, c: d.ink)),
          ),
        ],
      ),
    );
  }

  Widget fieldsColumn() {
    final d = context.desk;
    final level = <(String, String, String)>[
      ('volume_pattern', '卷', '留空使用内置卷规则'),
      ('level_chapter_pattern', '章', '留空使用常规标题规则'),
      ('section_pattern', '节', '留空使用内置节规则'),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('当前来源：$originLabel', style: ui(12, c: d.ink3)),
            const SizedBox(width: 4),
            DeskButton(
              '沿用导入默认',
              quiet: true,
              onPressed: busy
                  ? null
                  : () {
                      setState(
                        () => loadRules({
                          ...defaults!,
                          'origin': 'import_default',
                        }),
                      );
                      saveDraft();
                    },
            ),
            DeskButton(
              '恢复内置默认',
              quiet: true,
              onPressed: busy
                  ? null
                  : () => run(() async {
                      loadRules(await widget.session.builtin());
                      saveDraft();
                    }),
            ),
          ],
        ),
        const SizedBox(height: 12),
        label(
          '常规标题正则',
          hint: '留空使用内置规则',
          trailing: builtinInfo == null
              ? null
              : DeskButton(
                  '内置规则',
                  key: const ValueKey('rules-builtin-chapter'),
                  icon: Icons.visibility_outlined,
                  quiet: true,
                  tooltip: '查看内置规则识别哪些标题、排除哪些正文，以及参考正则',
                  onPressed: busy ? null : () => showBuiltin('chapter'),
                ),
        ),
        input('chapter_pattern', hint: '常规标题：留空使用经过正文排除的内置规则'),
        regexNote('chapter_pattern'),
        Text(
          '留空使用内置规则：第十二章、12章、第二卷、序章、番外等；“两章合一章”等作者说明作为正文。',
          style: ui(11.5, c: d.ink3, h: 1.5),
        ),
        const SizedBox(height: 12),
        switchRow('hierarchy', '按卷、章、节识别层级'),
        fold(
          '层级与高级表达式',
          advancedOpen,
          () => setState(() => advancedOpen = !advancedOpen),
          help: _helpLevels,
        ),
        if (advancedOpen) ...[
          for (final (key, name, hint) in level) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 30,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 9),
                    child: Text(name, style: ui(12, c: d.ink3)),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      input(key, hint: hint),
                      regexNote(key),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          SelectableText(
            r'例：^第(?<number>\d+)话\s*(?<title>.+)$。number为编号，title为标题；环视和反向引用不受支持。',
            style: ui(11.5, c: d.ink3, h: 1.5),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 6),
        switchRow('numeric', '识别纯数字标题，如 238：以命换伤'),
        if (rules!['numeric'] == true) ...[
          if (builtinInfo != null)
            Align(
              alignment: Alignment.centerRight,
              child: DeskButton(
                '内置数字标题规则',
                key: const ValueKey('rules-builtin-numeric'),
                icon: Icons.visibility_outlined,
                quiet: true,
                onPressed: busy ? null : () => showBuiltin('numeric'),
              ),
            ),
          input('numeric_pattern', hint: '数字标题正则：留空使用内置数字标题规则'),
          regexNote('numeric_pattern'),
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: [
              Text('候选标题后至少', style: ui(12, c: d.ink2)),
              SizedBox(width: 64, child: input('numeric_minimum_body_lines')),
              Text('行正文', style: ui(12, c: d.ink2)),
            ],
          ),
          checkRow(
            '识别并规范为“第一章 标题”',
            rules!['normalize_numeric_titles'] == true,
            busy
                ? null
                : (v) {
                    rules!['normalize_numeric_titles'] = v;
                    changed();
                  },
            key: const ValueKey('rules-normalize_numeric_titles'),
          ),
          Text('未勾选规范标题时保留原标题；此行数条件只用于纯数字候选。', style: ui(11.5, c: d.ink3)),
        ],
        const SizedBox(height: 8),
        fold(
          '编号错字表',
          correctionsOpen,
          () => setState(() => correctionsOpen = !correctionsOpen),
          help: _helpCorrections,
        ),
        if (correctionsOpen)
          input('number_corrections', hint: '每行原字=数字，例如 久=九；留空关闭', lines: 4),
        const SizedBox(height: 8),
        fold(
          '非标题词库与标题词库',
          phrasesOpen,
          () => setState(() => phrasesOpen = !phrasesOpen),
          help: _helpPhrases,
        ),
        if (phrasesOpen) ...[
          label('非标题词库', hint: '命中即不算标题'),
          input('non_heading', hint: '每行一条，如：两章合一章；re: 开头为正则', lines: 4),
          const SizedBox(height: 8),
          label('标题词库', hint: '命中即按章节识别'),
          input('force_heading', hint: '每行一条，如：楔子、引子', lines: 3),
        ],
        const SizedBox(height: 8),
        fold(
          '例外',
          exceptionsOpen,
          () => setState(() => exceptionsOpen = !exceptionsOpen),
          help: _helpExceptions,
        ),
        if (exceptionsOpen) ...[
          label('允许重复的标题', hint: '不再报连续重复标题'),
          input(
            'allowed_duplicate_titles',
            hint: '每行一条，如：上架感言、番外；re: 开头为正则',
            lines: 2,
          ),
          const SizedBox(height: 8),
          label('允许的编号跳跃', hint: '跳过的章号全在列表里才不报'),
          input('allowed_number_gaps', hint: '章号或范围，如：9，101-104'),
          const SizedBox(height: 8),
          label('标题后缀清理', hint: '只改标题，不动正文'),
          input('title_suffixes', hint: '每行一条，如：（求月票）；re: 开头为正则', lines: 2),
        ],
        if (widget.session.hasBook) ...[
          const SizedBox(height: 8),
          checkRow(
            '保留已确认“这是章节／这是正文”的位置',
            preserve,
            busy
                ? null
                : (v) {
                    preserve = v;
                    changed();
                  },
            key: const ValueKey('rules-preserve'),
          ),
        ],
        const SizedBox(height: 4),
        fold(
          '规则预设',
          presetsOpen,
          () => setState(() => presetsOpen = !presetsOpen),
          help: _helpPresets,
        ),
        if (presetsOpen)
          presetsPanel()
        else
          Text(
            presets.isEmpty
                ? '还没有自己保存的预设；展开可载入三套常用预设'
                : presets.map((p) => p['name']).join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ui(11.5, c: d.ink3),
          ),
      ],
    );
  }

  Widget presetsPanel() {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DeskChoice<String>(
          key: const ValueKey('rules-preset'),
          value: selectedPreset,
          isExpanded: true,
          decoration: deskInput(context),
          hint: Text('载入预设', style: ui(13, c: d.ink3)),
          items: [
            for (final name in commonRulePresets.keys)
              DropdownMenuItem(
                value: name,
                child: Text(name, style: ui(13, c: d.ink2)),
              ),
            for (final p in presets)
              DropdownMenuItem(
                value: p['name'] as String,
                child: Text(p['name'] as String, style: ui(13, c: d.ink)),
              ),
          ],
          onChanged: busy
              ? null
              : (name) {
                  if (name != null) loadPreset(name);
                },
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('rules-preset-name'),
          controller: presetName,
          style: ui(13, c: d.ink),
          decoration: deskInput(context, hint: '预设名称'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            DeskButton('保存预设', onPressed: busy ? null : () => run(savePreset)),
            DeskButton(
              '重命名',
              disabledReason: commonRulePresets.containsKey(selectedPreset)
                  ? '内置的常用预设不能改名'
                  : '先选择一个预设',
              onPressed:
                  busy ||
                      selectedPreset == null ||
                      commonRulePresets.containsKey(selectedPreset)
                  ? null
                  : () => run(() => savePreset(rename: true)),
            ),
            DeskButton(
              '删除',
              quiet: true,
              disabledReason: commonRulePresets.containsKey(selectedPreset)
                  ? '内置的常用预设不能删除'
                  : '先选择一个预设',
              onPressed:
                  busy ||
                      selectedPreset == null ||
                      commonRulePresets.containsKey(selectedPreset)
                  ? null
                  : () => run(deletePreset),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('同名覆盖；重命名不能与已有预设重名；删除不影响当前规则。', style: ui(11.5, c: d.ink3)),
      ],
    );
  }

  // ---------------------------------------------------------------- 右栏：试匹配与全书差异

  Widget trialsPanel() {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('单行试匹配', style: ui(12.5, w: 620, c: d.ink)),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const ValueKey('rules-sample'),
                controller: sample,
                style: ui(13, c: d.ink),
                decoration: deskInput(context, hint: '输入一行标题'),
                onSubmitted: (_) => busy ? null : run(trySample),
              ),
            ),
            const SizedBox(width: 6),
            DeskButton(
              '试匹配',
              icon: Icons.play_arrow_rounded,
              onPressed: busy ? null : () => run(trySample),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (trials.isEmpty)
          Text('试匹配只用当前字段，不改书稿；最近 8 次结果列在这里。', style: ui(11.5, c: d.ink3))
        else
          for (var i = 0; i < trials.length; i++)
            Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: i.isOdd ? d.sunken : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    trials[i].matched
                        ? Icons.check_rounded
                        : Icons.close_rounded,
                    size: 15,
                    color: trials[i].matched ? d.add : d.ink3,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trials[i].text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(13, c: d.ink),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      trials[i].result,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(11.5, c: d.ink2),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget stat(String value, String text, Color color) {
    final d = context.desk;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: d.sunken,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: ui(18, w: 680, c: color)),
            Text(text, style: ui(11.5, c: d.ink2)),
          ],
        ),
      ),
    );
  }

  String roleLabel(Object? value) => switch (value) {
    'volume' => '卷',
    'chapter' => '章',
    'section' => '节',
    'front' => '卷前',
    'body' => '正文',
    _ => '$value',
  };

  String changeDetail(Map v) =>
      '第 ${v['line']} 行'
      '${v['before'] != null && v['after'] != null && v['before'] != v['after'] ? ' · 原标题：${v['before']}' : ''}'
      '${v.containsKey('before_include_toc') && v['before_include_toc'] != v['include_toc'] ? ' · 目录：${v['before_include_toc'] == true ? '收录' : '不收录'} → ${v['include_toc'] == true ? '收录' : '不收录'}' : ''}'
      '${v.containsKey('before_depth') && v['before_depth'] != v['depth'] ? ' · 层级：${v['before_depth'] + 1} → ${v['depth'] + 1}' : ''}'
      '${v.containsKey('before_role') && v['before_role'] != v['role'] ? ' · 类型：${roleLabel(v['before_role'])} → ${roleLabel(v['role'])}' : ''}';

  Future<void> openChange(Map v) => showDialog<void>(
    context: context,
    builder: (ctx) {
      final d = ctx.desk;
      return DeskDialog(
        title: '第 ${v['line']} 行 · ${v['after'] ?? v['before']}',
        subtitle: changeDetail(v),
        closeTooltip: '返回规则预览',
        width: 520,
        actions: [
          DeskButton(
            '返回规则预览',
            primary: true,
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: d.paper,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: d.line),
          ),
          child: SelectableText(
            '${v['excerpt'] ?? ''}',
            style: serif(13.5, c: d.ink, h: 1.7),
          ),
        ),
      );
    },
  );

  Widget changeRow(Map v, int index) {
    final d = context.desk;
    final kind = v['kind'] as String?;
    final (tag, tone) = switch (kind) {
      'added' => ('新增', Tone.ok),
      'removed' => ('移除', Tone.pen),
      'changed' => ('变更', Tone.neutral),
      _ => ('匹配', Tone.neutral),
    };
    final before = v['before'];
    final after = v['after'];
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('rules-change-$index'),
        onTap: () => openChange(v),
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: d.line)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 64,
                child: Text('${v['line']}', style: mono(11, c: d.ink3)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${after ?? before}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(12.5, c: kind == 'removed' ? d.del : d.ink)
                          .copyWith(
                            decoration: kind == 'removed'
                                ? TextDecoration.lineThrough
                                : null,
                            decorationColor: d.del,
                          ),
                    ),
                    Text(
                      changeDetail(v),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(11, c: d.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              DeskTag(tag, tone),
            ],
          ),
        ),
      ),
    );
  }

  Widget diffPanel() {
    final d = context.desk;
    final data = preview?.data;
    final header = Row(
      children: [
        Text('全书差异', style: ui(12.5, w: 620, c: d.ink)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '只读预览 · 未应用',
            overflow: TextOverflow.ellipsis,
            style: ui(11.5, c: d.ink3),
          ),
        ),
        DeskButton(
          '全书试匹配与差异',
          icon: Icons.play_arrow_rounded,
          onPressed: busy || rules == null ? null : () => run(makePreview),
        ),
      ],
    );
    if (data == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 18),
          Center(
            child: Text(
              '生成全书差异后核对新增、移除与层级变化；应用前不改章节。',
              textAlign: TextAlign.center,
              style: ui(12, c: d.ink3, h: 1.5),
            ),
          ),
        ],
      );
    }
    final summary = data['summary'] as Map;
    final query = search.text.trim();
    final allChanges = (data['changes'] as List).cast<Map>();
    final allMatches = (data['matches'] as List).cast<Map>();
    final shown = (showMatches ? allMatches : allChanges)
        .where(
          (v) =>
              query.isEmpty ||
              '${v['before']} ${v['after']} ${v['line']}'.contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 10),
        Text(
          '当前 ${summary['before_count']} 项 → ${data['total']} 项；新增 ${summary['added']}，移除 ${summary['removed']}，变更 ${summary['changed']}',
          style: ui(12, c: d.ink2),
        ),
        for (final c
            in (data['check_changes'] as List? ?? const []).cast<Map>())
          Padding(
            key: ValueKey('rules-check-change-${c['id']}'),
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '检查：${c['title']} ${c['before']} 处 → ${c['after']} 处',
              style: ui(12, c: d.ink2),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            stat('+${summary['added']}', '新增标题', d.add),
            const SizedBox(width: 8),
            stat('−${summary['removed']}', '移除标题', d.del),
            const SizedBox(width: 8),
            stat('${summary['changed']}', '标题变更', d.ink),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            KeyedSubtree(
              key: const ValueKey('rules-show-matches'),
              child: DeskSegmented<bool>(
                value: showMatches,
                options: {
                  false: '变化 ${allChanges.length}',
                  true: '全部匹配 ${allMatches.length}',
                },
                onChanged: (v) => setState(() => showMatches = v),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('rules-search'),
                controller: search,
                style: ui(13, c: d.ink),
                onChanged: (_) => setState(() {}),
                decoration: deskInput(context, hint: '搜索变化标题或内容行号').copyWith(
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: d.ink3,
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 32),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: DeskListBox(
            paper: false,
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      query.isEmpty ? '没有变化' : '没有匹配的条目',
                      style: ui(12, c: d.ink3),
                    ),
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) => changeRow(shown[i], i),
                  ),
          ),
        ),
      ],
    );
  }

  Widget resultsColumn() {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message.isNotEmpty) ...[
            DeskNote(message, tone: failed ? Tone.warn : Tone.neutral),
            const SizedBox(height: 10),
          ],
          trialsPanel(),
          const SizedBox(height: 12),
          Divider(height: 1, color: d.line),
          const SizedBox(height: 12),
          Expanded(
            child: widget.session.hasBook
                ? diffPanel()
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 22,
                          color: d.ink3,
                        ),
                        const SizedBox(height: 8),
                        Text('导入默认只影响以后导入的书', style: ui(13, w: 600, c: d.ink2)),
                        const SizedBox(height: 4),
                        Text(
                          '全书试匹配与应用只在“本书识别规则”中提供。',
                          style: ui(12, c: d.ink3),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final book = widget.session.hasBook;
    final screen = MediaQuery.sizeOf(context);
    return DeskDialog(
      title: book ? '本书识别规则' : '导入默认规则',
      subtitle: book ? '先试匹配与预览全书差异；核对后作为一批应用，可整批撤销。' : '保存后只影响以后导入的书。',
      closeTooltip: '关闭（未应用的规则草稿会保留）',
      width: 1240,
      height: 880,
      busy: false,
      footerLeft: !book
          ? Text('只影响以后导入的书；现有章节树保持原状。', style: ui(12, c: d.ink2))
          : preview == null
          ? Text(
              [
                if (appliedFingerprint != null) '已应用规则 #$appliedFingerprint',
                if (appliedFingerprint != null &&
                    rules != null &&
                    editingFingerprint() != appliedFingerprint)
                  '编辑中 #${editingFingerprint()}（未应用）',
                '关闭不会应用；未应用的规则草稿会保留。',
              ].join(' · '),
              key: const ValueKey('rules-fingerprint'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ui(11.5, c: d.ink3),
            )
          : checkRow(
              '已核对新增、移除与手工结构变化，作为一批应用',
              confirmed,
              busy ? null : (v) => setState(() => confirmed = v),
              key: const ValueKey('rules-confirm'),
            ),
      actions: [
        DeskButton(
          '设为导入默认',
          primary: !book,
          onPressed: busy || rules == null ? null : () => run(saveDefault),
        ),
        if (book)
          DeskButton(
            '应用本书规则',
            primary: true,
            icon: Icons.check_rounded,
            disabledReason: preview == null ? '先生成全书差异' : '先勾选“已核对”',
            onPressed: busy || preview == null || !confirmed
                ? null
                : () => run(() async {
                    await widget.session.apply(preview!);
                    if (context.mounted) Navigator.pop(context);
                  }),
          ),
      ],
      child: rules == null
          ? Center(
              child: busy
                  ? const CircularProgressIndicator()
                  : Text(message, style: ui(12.5, c: d.pen)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 2,
                  child: busy
                      ? const LinearProgressIndicator(minHeight: 2)
                      : null,
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      if (c.maxWidth >= 860 && screen.height >= 560) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: (c.maxWidth * .42).clamp(360.0, 520.0),
                              child: ColoredBox(
                                color: d.canvas,
                                child: fieldsColumn(),
                              ),
                            ),
                            VerticalDivider(width: 1, color: d.line),
                            Expanded(child: resultsColumn()),
                          ],
                        );
                      }
                      // 窄窗：字段与结果分为两个页签，避免两栏都被挤坏。
                      return DefaultTabController(
                        length: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TabBar(
                              labelStyle: ui(12.5, w: 620),
                              tabs: const [
                                Tab(text: '规则'),
                                Tab(text: '试匹配与差异'),
                              ],
                            ),
                            Expanded(
                              child: TabBarView(
                                children: [fieldsColumn(), resultsColumn()],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// 内置规则说明（CH-248/249）：内容全部来自 Rust 的只读说明，不在界面里另写一份。
class _BuiltinRuleDialog extends StatelessWidget {
  const _BuiltinRuleDialog({required this.info, required this.numeric});
  final Map<String, dynamic> info;
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final regex =
        (numeric ? info['regex'] : info['reference_regex']) as String? ?? '';
    Widget section(String title, List items) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: ui(12.5, w: 620, c: d.ink)),
          const SizedBox(height: 4),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('· $item', style: ui(12.5, c: d.ink2, h: 1.5)),
            ),
        ],
      ),
    );
    return DeskDialog(
      title: numeric ? '内置数字标题规则' : '内置常规标题规则',
      subtitle: info['summary'] as String?,
      closeTooltip: '关闭内置规则说明',
      width: 640,
      actions: [
        DeskButton('关闭', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          '以此为起点修改',
          key: const ValueKey('rules-builtin-seed'),
          icon: Icons.edit_outlined,
          tooltip: '把下面的正则填入输入框；仍需试匹配、预览后应用',
          onPressed: regex.isEmpty ? null : () => Navigator.pop(context, regex),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (info['forms'] is List) section('识别形式', info['forms'] as List),
          if (info['exclusions'] is List)
            section('不算标题（正文排除）', info['exclusions'] as List),
          if (info['notes'] is List) section('条件', info['notes'] as List),
          if (info['hierarchy'] is String) section('层级', [info['hierarchy']]),
          const SizedBox(height: 14),
          Text(
            numeric ? '内置正则' : '参考正则（只对应识别形式）',
            style: ui(12.5, w: 620, c: d.ink),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: d.canvas,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: d.line),
            ),
            child: SelectableText(
              regex,
              key: const ValueKey('rules-builtin-regex'),
              style: mono(12, c: d.ink),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            (numeric ? info['edit_note'] : info['reference_note']) as String? ??
                '',
            style: ui(11.5, c: d.ink3, h: 1.5),
          ),
        ],
      ),
    );
  }
}
