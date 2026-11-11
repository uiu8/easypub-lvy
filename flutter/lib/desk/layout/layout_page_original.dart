// 排版页“原书样式”分页：保持原格式的书改样式。
// 原书文件不改，这里的设置只影响生成的成品，软件排版的书不生效。
part of 'layout_page.dart';

/// 去除原书样式的选项：名字 → 对应的 CSS 属性。
const originalStyleGroups = <String, List<String>>{
  '字体': ['font-family'],
  '字号': ['font-size'],
  '颜色': ['color'],
  '背景': ['background'],
  '行高': ['line-height'],
  '段距': ['margin-top', 'margin-bottom'],
  '缩进': ['text-indent'],
  '对齐': ['text-align'],
};

extension _LayoutOriginalSection on _LayoutPageState {
  bool get isEpubSource => widget.library.books.value.any(
    (b) => b.id == widget.bookId && b.format.toUpperCase() == 'EPUB',
  );

  bool get keepsOriginal => widget.keepsOriginal?.call() ?? false;

  /// 书稿里的设置读进控件。
  void readOriginalStyle(Map<String, Object?> saved) {
    final value = (saved['original_style'] as Map?)?.cast<String, dynamic>();
    originalStyle = {...?value};
    final known = originalStyleGroups.values.expand((v) => v).toSet();
    originalCustom.text = [
      for (final p in (value?['filter_css'] as List?) ?? const [])
        if (!known.contains(p)) p,
    ].join(', ');
    originalCss.text = value?['extra_css'] as String? ?? '';
    for (final e in originalMargins.entries) {
      e.value.text = value?[e.key] as String? ?? '';
    }
  }

  /// 单独应用（进变更记录），不经草稿；和嵌入字体一样属于本书。
  Future<void> applyOriginalStyle(Map<String, dynamic> next) async {
    if (session == null) return;
    update(() => busy = true);
    try {
      await session!.apply(await session!.preview({'original_style': next}));
      if (mounted) {
        update(() {
          originalStyle = next;
          originalError = '';
          message = '已保存，转换时生效';
        });
      }
    } catch (error) {
      if (mounted) {
        update(
          () => originalError = deskErrorText(
            error,
            '没有保存：页边距写法如 1em、12px、5%，附加 CSS 不能用 url() 和 @import。',
          ),
        );
      }
    } finally {
      if (mounted) update(() => busy = false);
    }
  }

  List<String> get _filters =>
      ((originalStyle['filter_css'] as List?) ?? const []).cast<String>();

  void _toggleGroup(List<String> properties, bool on) {
    final rest = [
      for (final p in _filters)
        if (!properties.contains(p)) p,
    ];
    applyOriginalStyle({
      ...originalStyle,
      'filter_css': [...rest, if (on) ...properties],
    });
  }

  /// 输入框里的内容一起保存。
  void _saveOriginalInputs() {
    final known = originalStyleGroups.values.expand((v) => v).toSet();
    final custom = [
      for (final p in originalCustom.text.split(RegExp(r'[,，\s]+')))
        if (p.trim().isNotEmpty) p.trim().toLowerCase(),
    ];
    applyOriginalStyle({
      ...originalStyle,
      'filter_css': [
        ..._filters.where(known.contains),
        ...custom.where((p) => !known.contains(p)),
      ],
      'extra_css': originalCss.text,
      for (final e in originalMargins.entries) e.key: e.value.text.trim(),
    });
  }

  /// 原书字体的个数和总大小。
  (int, int) get _originalFontSize {
    var bytes = 0;
    final fonts = _fonts?.originalFonts ?? const <Map<String, Object?>>[];
    for (final f in fonts) {
      try {
        bytes += File(f['path'] as String).lengthSync();
      } catch (_) {
        // 文件读不到时只少算大小。
      }
    }
    return (fonts.length, bytes);
  }

  List<Widget> originalStyleControls() {
    final d = context.desk;
    final (count, bytes) = _originalFontSize;
    final remove = originalStyle['remove_fonts'] == true;
    final filters = _filters;
    final off = busy;
    return [
      group('转换方式', [
        Row(
          children: [
            Expanded(
              child: Text(
                keepsOriginal
                    ? '这本书转换时保持原格式，下面的设置会生效。'
                    : '这本书转换时用软件排版，下面的设置不生效。',
                key: const ValueKey('layout-original-mode'),
                style: ui(12.5, c: keepsOriginal ? d.ink2 : d.warn, h: 1.5),
              ),
            ),
            if (widget.setKeepsOriginal != null)
              Switch(
                key: const ValueKey('layout-original-switch'),
                value: keepsOriginal,
                onChanged: off
                    ? null
                    : (v) => update(() => widget.setKeepsOriginal!(v)),
              ),
          ],
        ),
      ]),
      group('封面', [
        optionSwitch(
          '删除与封面重复的第一张图',
          originalStyle['remove_first_image'] == true,
          (v) =>
              applyOriginalStyle({...originalStyle, 'remove_first_image': v}),
          key: const ValueKey('layout-original-first-image'),
          note: '只移除正文里的首图，且须与封面引用同一资源。',
        ),
      ]),
      group('原书字体', [
        Text(
          count == 0
              ? '这本书没有带字体。'
              : '$count 个，共 ${(bytes / 1048576).toStringAsFixed(1)} MB',
          key: const ValueKey('layout-original-fonts'),
          style: ui(12.5, c: d.ink2),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: KeyedSubtree(
            key: const ValueKey('layout-original-font-mode'),
            child: DeskSegmented<bool>(
              value: remove,
              options: const {false: '保留', true: '去除'},
              onChanged: off
                  ? null
                  : (v) => applyOriginalStyle({
                      ...originalStyle,
                      'remove_fonts': v,
                    }),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text('去除后书变小，阅读器用自己的字体。原书文件不改。', style: ui(11.5, c: d.ink3, h: 1.5)),
      ]),
      group('去除原书样式', [
        Wrap(
          spacing: 2,
          runSpacing: 0,
          children: [
            for (final e in originalStyleGroups.entries)
              SizedBox(
                width: 84,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      key: ValueKey('layout-original-filter-${e.key}'),
                      visualDensity: VisualDensity.compact,
                      value: e.value.every(filters.contains),
                      onChanged: off
                          ? null
                          : (v) => _toggleGroup(e.value, v == true),
                    ),
                    Text(e.key, style: ui(12.5, c: d.ink)),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          key: const ValueKey('layout-original-custom'),
          controller: originalCustom,
          enabled: !off,
          style: ui(12.5, c: d.ink),
          decoration: deskInput(context).copyWith(hintText: '其他属性，用逗号分开'),
        ),
      ]),
      group('页边距', [
        Row(
          children: [
            for (final (i, e) in originalMargins.entries.indexed) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  key: ValueKey('layout-original-${e.key}'),
                  controller: e.value,
                  enabled: !off,
                  style: mono(12, c: d.ink),
                  decoration: deskInput(context).copyWith(
                    hintText: const {
                      'margin_top': '上',
                      'margin_bottom': '下',
                      'margin_left': '左',
                      'margin_right': '右',
                    }[e.key],
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text('空着不改。写法如 1em、12px、5%。', style: ui(11.5, c: d.ink3)),
      ]),
      group('附加 CSS', [
        TextField(
          key: const ValueKey('layout-original-css'),
          controller: originalCss,
          enabled: !off,
          minLines: 4,
          maxLines: 8,
          style: mono(12, c: d.ink),
          decoration: deskInput(context)
              .copyWith(hintText: 'p { text-indent: 2em; }'),
        ),
        const SizedBox(height: 6),
        Text('接在原书样式最后。不能用 url() 和 @import。', style: ui(11.5, c: d.ink3)),
      ]),
      if (originalError.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            originalError,
            key: const ValueKey('layout-original-error'),
            style: ui(12, c: d.pen, h: 1.5),
          ),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: DeskButton(
          '保存输入框的内容',
          key: const ValueKey('layout-original-save'),
          onPressed: off ? null : _saveOriginalInputs,
        ),
      ),
    ];
  }
}
