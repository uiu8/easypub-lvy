part of 'layout_page.dart';

extension _LayoutImages on _LayoutPageState {
  void changeImage(String key, Object value) => edit(() {
    imageOptions = {...imageOptions, key: value};
  });

  void scheduleImageEstimate() {
    final source = session;
    if (source is! ImageEstimateSource) return;
    final options = Map<String, dynamic>.of(imageOptions);
    final key = jsonEncode([
      widget.bookId,
      options,
      keepsOriginal,
      optionsRevision,
    ]);
    if (imageEstimateKey == key) return;
    imageEstimateKey = key;
    Future<void>.delayed(const Duration(milliseconds: 450), () async {
      if (!mounted || imageEstimateKey != key) return;
      try {
        final result = await (source as ImageEstimateSource).estimateImages(
          options,
          original: keepsOriginal,
        );
        if (!mounted || imageEstimateKey != key) return;
        String mb(Object? bytes) =>
            ((bytes as num) / 1048576).toStringAsFixed(2);
        update(
          () => imageEstimate = result['count'] == 0
              ? '这本书没有图片。'
              : "全书 ${result['count']} 张图，处理前 ${mb(result['before'])} MB，预计 ${mb(result['after'])} MB（图片资源）",
        );
      } catch (_) {
        if (mounted && imageEstimateKey == key) {
          update(() => imageEstimate = '图片估算失败，请检查资源是否可读');
        }
      }
    });
  }

  Widget imageControls() {
    scheduleImageEstimate();
    final d = context.desk;
    final size = '${imageOptions['max_long']}x${imageOptions['max_short']}';
    const sizes = {
      '0x0': '不限',
      '2560x1600': '2560 × 1600',
      '1600x1200': '1600 × 1200',
      '1200x900': '1200 × 900',
      'custom': '自定义',
    };
    void chooseSize(String value) {
      final parts = value == 'custom'
          ? const [2000, 1500]
          : value.split('x').map(int.parse).toList();
      edit(
        () => imageOptions = {
          ...imageOptions,
          'max_long': parts[0],
          'max_short': parts[1],
        },
      );
    }

    return group('图片', [
      if (imageEstimate.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            imageEstimate,
            key: const ValueKey('layout-image-estimate'),
            style: ui(12, c: d.ink2, h: 1.5),
          ),
        ),
      optionChoice<String>(
        '最大尺寸（长边 × 短边）',
        sizes.containsKey(size) ? size : 'custom',
        sizes,
        chooseSize,
        key: const ValueKey('layout-image-size'),
      ),
      if (!sizes.containsKey(size))
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, k) in const ['max_long', 'max_short'].indexed) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(
                child: optionText(
                  k == 'max_long' ? '长边' : '短边',
                  '${imageOptions[k]}',
                  (v) {
                    final n = int.tryParse(v);
                    if (n != null) changeImage(k, n);
                  },
                  key: ValueKey(('image-$k', widget.bookId, optionsRevision)),
                  number: true,
                  suffix: '像素',
                ),
              ),
            ],
          ],
        ),
      Row(
        children: [
          const Expanded(child: DeskLabel('JPEG 质量')),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${imageOptions['quality']}',
              style: mono(12.5, c: d.ink),
            ),
          ),
        ],
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          activeTrackColor: d.accent,
          inactiveTrackColor: d.line,
          thumbColor: d.accent,
          overlayShape: SliderComponentShape.noOverlay,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
        child: SizedBox(
          height: 22,
          child: Slider(
            key: const ValueKey('layout-image-quality'),
            min: 40,
            max: 100,
            divisions: 60,
            value: (imageOptions['quality'] as num).toDouble(),
            onChanged: busy ? null : (v) => changeImage('quality', v.round()),
          ),
        ),
      ),
      const SizedBox(height: 8),
      for (final e in const {
        'png_to_jpeg': '不透明 PNG 转 JPEG',
        'grayscale': '转成灰度',
        'preserve_cover': '封面保持原处理',
        'recompress_jpeg': '重新压缩所有 JPEG',
      }.entries)
        optionSwitch(
          e.value,
          imageOptions[e.key] == true,
          (v) => changeImage(e.key, v),
          key: ValueKey(('layout-image-option', e.key)),
        ),
      const SizedBox(height: 4),
      Text(
        '未超限的图片默认保留原字节。质量只影响需要处理的图片；透明 PNG 保持透明。',
        style: ui(11.5, c: d.ink3, h: 1.5),
      ),
    ]);
  }

  /// 新增选项的统一写法（标题在上、控件在下），和“字号”“对齐”那些字段一样。
  Widget optionLabeled(String label, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [DeskLabel(label), child],
    ),
  );

  /// 选项多或字长，用下拉；两三个短选项用 [optionSegments]。
  Widget optionChoice<T>(
    String label,
    T? value,
    Map<T, String> options,
    ValueChanged<T> onChanged, {
    Key? key,
    bool searchable = false,
  }) => optionLabeled(
    label,
    DeskChoice<T>(
      key: key,
      value: value,
      searchable: searchable,
      decoration: deskInput(context),
      items: [
        for (final e in options.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: busy
          ? null
          : (v) {
              if (v != null) onChanged(v);
            },
    ),
  );

  Widget optionSegments<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T> onChanged, {
    Key? key,
  }) => optionLabeled(
    label,
    Align(
      alignment: Alignment.centerLeft,
      child: KeyedSubtree(
        key: key,
        child: DeskSegmented<T>(
          value: value,
          options: options,
          onChanged: busy ? null : onChanged,
        ),
      ),
    ),
  );

  Widget optionText(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    Key? key,
    String? note,
    String? error,
    String? suffix,
    bool number = false,
  }) {
    final d = context.desk;
    return optionLabeled(
      label,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            key: key,
            initialValue: value,
            enabled: !busy,
            keyboardType: number ? TextInputType.number : null,
            style: number ? mono(13, c: d.ink) : ui(13, c: d.ink),
            decoration: deskInput(context, error: error).copyWith(
              suffixText: suffix,
              suffixStyle: ui(12, c: d.ink3),
            ),
            onChanged: onChanged,
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(note, style: ui(11.5, c: d.ink3, h: 1.4)),
            ),
        ],
      ),
    );
  }

  /// 和“成品结构”的开关同样的一行，整行都能点。
  Widget optionSwitch(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    Key? key,
    String? note,
  }) {
    final d = context.desk;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: busy ? null : () => onChanged(!value),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: ui(12.5, c: d.ink)),
                if (note != null)
                  Text(note, style: ui(11.5, c: d.ink3, h: 1.4)),
              ],
            ),
          ),
          Switch(key: key, value: value, onChanged: busy ? null : onChanged),
        ],
      ),
    );
  }
}
