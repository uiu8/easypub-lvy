// 排版页“文字”分页与各分页共用的表单件（R5-13 从 layout_page.dart 拆出，逻辑不变）。
part of 'layout_page.dart';

extension _LayoutTextSection on _LayoutPageState {
  Widget field(String key) {
    final d = context.desk;
    final unitKey = key == 'font_size'
        ? 'font_size_unit'
        : key.startsWith('margin_')
        ? '${key}_unit'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分列时按最长标题决定列数（LAY-103），同一行的标题都放得下，输入框保持对齐；
        // 只剩一列仍放不下时标题换行，不再省略。原来标题与 Spacer 平分剩余宽度，
        // 较长的标题因此被省略；现在标题与帮助图标占用单位切换以外的全部宽度。
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Tooltip(
                        message: key == 'fullwidth_indent'
                            ? '段首全角空格'
                            : layoutNumbers[key]!,
                        child: Text(
                          key == 'fullwidth_indent'
                              ? '段首全角空格'
                              : layoutNumbers[key]!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ui(12, w: 600, c: d.ink2),
                        ),
                      ),
                    ),
                  ),
                  if (_LayoutPageState._indentHelp[key] case final help?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: DeskHelp(help, key: ValueKey('layout-help-$key')),
                    ),
                ],
              ),
            ),
            if (unitKey != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: KeyedSubtree(
                  key: ValueKey('layout-$unitKey'),
                  child: DeskSegmented<String>(
                    value: units[unitKey]!,
                    options: key == 'font_size'
                        ? const {'%': '%', 'px': 'px'}
                        : const {'em': 'em', 'px': 'px'},
                    onChanged: busy
                        ? null
                        : (value) => key == 'font_size'
                              ? edit(() {
                                  if (value == units['font_size_unit']) return;
                                  final old =
                                      double.tryParse(numbers[key]!.text) ?? 18;
                                  numbers[key]!.text =
                                      (value == '%'
                                              ? old / 16 * 100
                                              : old * 16 / 100)
                                          .toStringAsFixed(1);
                                  units['font_size_unit'] = value;
                                })
                              : edit(() => units[unitKey] = value),
                  ),
                ),
              ),
          ],
        ),
        TextField(
          key: ValueKey('layout-$key'),
          controller: numbers[key],
          enabled: !busy,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: mono(13, c: d.ink),
          decoration: deskInput(context).copyWith(
            suffixText: suffix(key),
            suffixStyle: ui(12, c: d.ink3),
          ),
        ),
      ],
    );
  }

  Widget grid(List<String> keys) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: LayoutBuilder(
      builder: (context, c) {
        // 列数按最长的标题行决定（LAY-103）：标题、帮助图标与单位切换都放得下才分列，
        // 输入框至少 120 宽；否则减少列数（设置区收窄后见 LAY-100）。
        final widest = keys.map(labelRowWidth).fold(120.0, math.max);
        var columns = keys.length;
        while (columns > 1 &&
            (c.maxWidth - 10 * (columns - 1)) / columns < widest) {
          columns--;
        }
        final width = (c.maxWidth - 10 * (columns - 1)) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final key in keys) SizedBox(width: width, child: field(key)),
          ],
        );
      },
    ),
  );

  Widget group(String title, List<Widget> children) {
    final d = context.desk;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: ui(13, w: 650, c: d.ink)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        key: const ValueKey('layout-settings-actions'),
        padding: const EdgeInsets.fromLTRB(20, 10, 14, 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: context.desk.line)),
        ),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DeskButton(
              '应用我的默认排版',
              quiet: true,
              icon: Icons.auto_awesome_outlined,
              onPressed: busy ? null : applyClassicDefaults,
            ),
            DeskButton(
              '撤销未应用输入',
              quiet: true,
              icon: Icons.undo_rounded,
              onPressed: busy ? null : discardInput,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 14, 0),
        child: KeyedSubtree(
          key: const ValueKey('layout-tabs'),
          child: DeskSegmented<int>(
            value: settingsTab,
            options: _LayoutPageState.settingsTabs,
            onChanged: (value) => update(() => settingsTab = value),
          ),
        ),
      ),
      Expanded(child: settingsList()),
    ],
  );

  /// 段落与识别里的一项：收起时一行显示名称与当前选择，点开才显示选项。
  Widget foldRow({
    required String field,
    required String label,
    required Widget help,
    required String current,
    required Widget control,
  }) {
    final d = context.desk;
    final open = expandedRows.contains(field);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: d.surface,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            key: ValueKey('layout-row-$field'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => update(
              () => open ? expandedRows.remove(field) : expandedRows.add(field),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Text(label, style: ui(12.5, w: 600, c: d.ink)),
                  help,
                  // 当前选择贴右对齐（V121：原来 Spacer 与 Flexible 平分剩余宽度，各行错位）。
                  Expanded(
                    child: Text(
                      current,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: ui(12, c: d.ink2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: d.ink3,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 2, 0, 8),
            child: control,
          ),
        Divider(height: 1, color: d.line),
      ],
    );
  }

  /// 书写方向、竖排数字横排与注音/着重号写法（V28，LAY-104–107）。
  Widget writingControls() {
    final d = context.desk;
    final vertical = writingMode == 'vertical';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const DeskLabel('书写方向'),
        Align(
          alignment: Alignment.centerLeft,
          child: KeyedSubtree(
            key: const ValueKey('layout-writing_mode'),
            child: DeskSegmented<String>(
              value: writingMode,
              options: const {'horizontal': '横排', 'vertical': '竖排'},
              onChanged: busy
                  ? null
                  : (value) => edit(() => writingMode = value),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const DeskLabel('竖排中数字横排'),
        Row(
          children: [
            // 横排时控件自身变淡（onChanged 为 null）；Flexible 让窄栏里按比例缩小。
            Flexible(
              child: KeyedSubtree(
                key: const ValueKey('layout-vertical_digits'),
                child: DeskSegmented<int>(
                  value: verticalDigits,
                  options: const {
                    0: '不横排',
                    1: '1 位',
                    2: '2 位',
                    3: '3 位',
                    4: '4 位',
                  },
                  onChanged: busy || !vertical
                      ? null
                      : (value) => edit(() => verticalDigits = value),
                ),
              ),
            ),
            const DeskHelp(
              '竖排时从右往左翻页；不超过所选位数、前后不连字母的半角数字横着排（如 12 月），更长的仍竖排。横排时不生效。',
            ),
          ],
        ),
        const SizedBox(height: 10),
        // 这是写法说明，不是设置项：写成一行浅色说明，详细的放在问号里（R5-08）。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                '写法：｜汉字《hàn zì》生成注音，｜重点《・》生成着重号。',
                style: ui(11.5, c: d.ink3),
              ),
            ),
            const DeskHelp(
              '正文里写“｜汉字《hàn zì》”生成注音，写“｜重点《・》”生成着重号。必须用全角竖线“｜”开头，普通书名号《》不受影响。目录和书名里只保留基础文字。',
              key: ValueKey('layout-help-inline-markup'),
            ),
          ],
        ),
      ],
    );
  }

  Widget headingTile(String value, String label) {
    final d = context.desk;
    final selected = headingStyle == value;
    return Semantics(
      selected: selected,
      button: true,
      label: '章节标题样式：$label',
      child: Material(
        color: d.surface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: ValueKey('layout-heading_style-$value'),
          borderRadius: BorderRadius.circular(8),
          onTap: busy ? null : () => edit(() => headingStyle = value),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              selected ? 5 : 6,
              selected ? 5 : 6,
              selected ? 5 : 6,
              selected ? 4 : 5,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? d.accent : d.line,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: HeadingSample(
                    look: headingLooks[value]!,
                    ink: d.ink,
                    muted: d.line,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(
                    11.5,
                    w: selected ? 600 : 400,
                    c: selected ? d.ink : d.ink2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget settingsList() {
    final d = context.desk;
    return ListView(
      key: ValueKey(('layout-tab', settingsTab)),
      padding: const EdgeInsets.fromLTRB(20, 12, 14, 16),
      children: switch (settingsTab) {
        1 => [
          group('标题', [
            headingControls(),
            const SizedBox(height: 14),
            chapterHeadControls(),
            const SizedBox(height: 14),
            chapterStyleControls(),
          ]),
        ],
        2 => [
          group('段落', [firstParagraphControls(), rareCharControls()]),
          group('自动识别', [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '原文不改，只影响成品；在章节页可以手工标注，手工优先于自动识别。',
                style: ui(11.5, c: d.ink3),
              ),
            ),
            sceneBreakControls(),
            systemControls(),
            blockControls(
              '诗词',
              '整行是五言或七言对句（如“床前明月光，疑是地上霜。”），相邻几行合成一组；'
                  '紧跟其后以“——”开头的一行作为署名，靠右。自由体诗、歌词识别不了。原文不改。',
              'verse_block_style',
              verseBlockStyle,
              verseBlockStyles,
              (value) => verseBlockStyle = value,
            ),
            blockControls(
              '弹出注释',
              '识别同一章内成对的注释：正文里有 ①、[1]、〔1〕、[注1] 等标记，后面有一行以同样标记开头'
                  '（或写成“注①：”“注1：”）的注释。点标记弹出注释，注释前的标记可点回正文；'
                  '注释行仍留在原位置。不成对、重复或跨章的原样保留，原文不改。'
                  'AZW3、KFX 在 Kindle 上显示为弹窗，MOBI 旧格式为跳转后返回。小预览不显示弹窗效果。',
              'note_style',
              noteStyle,
              noteStyles,
              (value) => noteStyle = value,
            ),
          ]),
          // 场景样式（V81，LAY-135）。
          group('场景样式', [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '动态、论坛楼层、日记、古籍、诏书、羊皮纸、告示、剪报：在章节页选中正文行标注。',
                style: ui(11.5, c: d.ink3),
              ),
            ),
            blockControls(
              '聊天记录',
              '自动识别连续的“名字：内容”行（可带【】[ ]［ ］，名字不超过 6 个字，有人说话两次以上），'
                  '中间可以夹空行和时间行。识别出的聊天优先于系统提示。“不识别”时，章节页手工标注的聊天按群聊窗口排。'
                  '原文不改；同时用于 EPUB、AZW3、MOBI、KFX。',
              'chat_block_style',
              chatBlockStyle,
              chatBlockStyles,
              (value) {
                chatBlockStyle = value;
                if (value != 'off' && insetStyles != null) {
                  insetStyles = {...insetStyles!}..remove('chat');
                  if (insetStyles!.isEmpty) insetStyles = null;
                }
              },
            ),
            blockControls(
              '书信',
              '章节页标为“书信”的段落：信笺格线在每行下画虚线，落款靠右。',
              'letter_block_style',
              letterBlockStyle,
              letterBlockStyles,
              (value) => letterBlockStyle = value,
            ),
            blockControls(
              '场景字体',
              '书信（信笺格线）、古籍、诏书用楷体。Kindle 实测：KFX 里显示楷体；AZW3 由转换器去掉字体设置，用阅读器字体。',
              'inset_font',
              insetFont,
              insetFonts,
              (value) => insetFont = value,
            ),
            insetDetectControls(),
            insetStyleControls(),
          ]),
        ],
        3 => pageAndStructure(),
        _ => [
          group('文字', [
            grid(['font_size', 'line_height']),
            const DeskLabel('对齐'),
            Align(
              alignment: Alignment.centerLeft,
              child: KeyedSubtree(
                key: const ValueKey('layout-text_alignment'),
                child: DeskSegmented<String>(
                  value: alignment,
                  options: const {
                    'start': '随文字方向',
                    'justify': '两端对齐',
                    'left': '左对齐',
                    'center': '居中',
                    'right': '右对齐',
                  },
                  onChanged: busy
                      ? null
                      : (value) => edit(() => alignment = value),
                ),
              ),
            ),
            const SizedBox(height: 10),
            grid(['paragraph_indent', 'paragraph_spacing', 'fullwidth_indent']),
            const SizedBox(height: 4),
            writingControls(),
            fontControls(),
          ]),
        ],
      },
    );
  }
}
