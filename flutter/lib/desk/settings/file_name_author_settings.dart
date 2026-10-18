import 'package:flutter/material.dart';

import '../../prototype/file_name_metadata.dart';
import '../controls/controls.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 设置 · 导入：从文件名提取作者（V72，LIB-116）。
/// 方式、自定义格式、书名里是否去掉作者名，以及即时的“试一试”。
class FileNameAuthorSettings extends StatefulWidget {
  const FileNameAuthorSettings({
    super.key,
    required this.configuration,
    required this.saving,
    required this.save,
  });

  final Map<String, dynamic> configuration;
  final bool saving;
  final Future<bool> Function(Map<String, dynamic> patch) save;

  @override
  State<FileNameAuthorSettings> createState() => _FileNameAuthorSettingsState();
}

const _examples = [
  '沧元图(我吃西红柿) (1).txt',
  '东京：从租借男友开始当完美男神(圭寸笔).txt',
  '《希灵帝国》（校对版全本）作者：远瞳.txt',
  '红楼梦（上）.txt',
];

class _FileNameAuthorSettingsState extends State<FileNameAuthorSettings> {
  late final pattern = TextEditingController(text: options.pattern);
  final sample = TextEditingController(text: _examples.first);

  FileNameOptions get options =>
      FileNameOptions.fromConfiguration(widget.configuration);

  @override
  void didUpdateWidget(FileNameAuthorSettings old) {
    super.didUpdateWidget(old);
    final saved = options.pattern;
    if (old.configuration['filename_pattern'] !=
            widget.configuration['filename_pattern'] &&
        pattern.text != saved) {
      pattern.text = saved;
    }
  }

  @override
  void dispose() {
    pattern.dispose();
    sample.dispose();
    super.dispose();
  }

  /// 试一试用编辑中的格式（有效时），保存前就能看到结果。
  FileNameOptions get trial => FileNameOptions(
    mode: options.mode,
    pattern: isValidFileNamePattern(pattern.text) ? pattern.text.trim() : '',
    stripAuthor: options.stripAuthor,
  );

  Future<void> applyPattern() async {
    if (!isValidFileNamePattern(pattern.text)) return;
    await widget.save({'filename_pattern': pattern.text.trim()});
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final o = options;
    final custom = o.mode == 'custom';
    final valid = isValidFileNamePattern(pattern.text);
    final changed = pattern.text.trim() != o.pattern;
    Widget label(String text, [String help = '']) => SizedBox(
      width: 150,
      child: Row(
        children: [
          Flexible(
            child: Text(text, style: ui(13, c: d.ink)),
          ),
          if (help.isNotEmpty) DeskHelp(help),
        ],
      ),
    );
    final names = [
      if (sample.text.trim().isNotEmpty) sample.text.trim(),
      ..._examples.skip(1),
    ];
    return Column(
      key: const ValueKey('settings-filename-author'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              label(
                '从文件名提取作者',
                '导入时书里没有作者信息，就从文件名里取。自动识别认“书名(作者)”“《书名》作者：某某”等写法，'
                    '并去掉末尾的“ (1)”重复编号；括号里是“上、下、卷、册、番外”或数字时不当作者。'
                    '只影响以后导入的书和刷新来源时的候选，不改已入库的书。',
              ),
              Flexible(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: KeyedSubtree(
                    key: const ValueKey('settings-filename_author_mode'),
                    child: DeskSegmented<String>(
                      value: o.mode,
                      options: fileNameAuthorModes,
                      onChanged: widget.saving
                          ? null
                          : (v) => widget.save({'filename_author_mode': v}),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              label(
                '文件名格式',
                '用 {书名}、{作者}、{*}（任意内容，忽略）写出文件名的样子，如 {书名}({作者})、{作者} - {书名}、[{*}]{书名}。整个文件名（不含扩展名和重复编号）都要符合，不符合时不提取。',
              ),
              Expanded(
                child: TextField(
                  key: const ValueKey('settings-filename_pattern'),
                  controller: pattern,
                  enabled: custom && !widget.saving,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    errorText: custom && !valid
                        ? '需要恰好一个 {书名}，{作者} 最多一个'
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => applyPattern(),
                ),
              ),
              const SizedBox(width: 8),
              DeskButton(
                '应用',
                key: const ValueKey('settings-filename_pattern-apply'),
                onPressed: custom && valid && changed && !widget.saving
                    ? applyPattern
                    : null,
              ),
            ],
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('settings-filename_strip_author'),
            onTap: widget.saving
                ? null
                : () => widget.save({'filename_strip_author': !o.stripAuthor}),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  label('书名里去掉作者名', '关掉时书名保留整个文件名，只把作者另外填好。'),
                  const Spacer(),
                  Switch(
                    value: o.stripAuthor,
                    onChanged: widget.saving
                        ? null
                        : (v) => widget.save({'filename_strip_author': v}),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              label('试一试'),
              Expanded(
                child: TextField(
                  key: const ValueKey('settings-filename-sample'),
                  controller: sample,
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Table(
          key: const ValueKey('settings-filename-results'),
          columnWidths: const {
            0: FlexColumnWidth(5),
            1: FlexColumnWidth(4),
            2: FlexColumnWidth(2),
          },
          children: [
            TableRow(
              children: [
                for (final h in ['文件名', '书名', '作者'])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(h, style: ui(12, c: d.ink3)),
                  ),
              ],
            ),
            for (final name in names)
              () {
                final r = fileNameMetadata(name, trial);
                return TableRow(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: d.line)),
                  ),
                  children: [
                    for (final (text, color) in [
                      (name, d.ink2),
                      (r.title, d.ink),
                      (
                        r.author.isEmpty ? '（无）' : r.author,
                        r.author.isEmpty ? d.ink3 : d.ink,
                      ),
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(text, style: ui(12.5, c: color)),
                      ),
                  ],
                );
              }(),
          ],
        ),
      ],
    );
  }
}
