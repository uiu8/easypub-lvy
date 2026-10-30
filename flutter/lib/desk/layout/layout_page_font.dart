// 排版页“文字”分页：嵌入字体（V123，LAY-179）。
part of 'layout_page.dart';

extension _LayoutFontSection on _LayoutPageState {
  BookFontSource? get _fonts => switch (session) {
    final BookFontSource fonts => fonts,
    _ => null,
  };

  /// 嵌入字体单独应用（进变更记录），不经草稿；与章首图一样属于本书。
  Future<void> setFontResource(Map<String, Object?>? selection) async {
    if (session == null) return;
    update(() => busy = true);
    try {
      await session!.apply(
        await session!.preview({'font_resource': selection}),
      );
      if (mounted) {
        update(() {
          fontResource = selection?.cast<String, dynamic>();
          fontFamily = selection == null ? null : fontFamily;
          message = selection == null ? '已取消嵌入字体' : '已设置嵌入字体，转换时只放入书里用到的字';
        });
      }
    } catch (error) {
      if (mounted) {
        update(() => message = deskErrorText(error, '嵌入字体未能应用'));
      }
    } finally {
      if (mounted) update(() => busy = false);
    }
  }

  /// 检查字体、确认授权，复制到程序数据目录后写进本书。
  Future<void> chooseFont(String path, {String? origin}) async {
    final fonts = _fonts;
    if (fonts == null) return;
    Map<String, dynamic> report;
    try {
      report = await fonts.inspectFont(path);
    } catch (_) {
      if (mounted) {
        update(
          () => message = origin == null
              ? '读不了这个字体文件，请选 TTF、OTF 或 TTC 字体。'
              : '原书字体“$origin”读不了（可能是 WOFF2 或加密方式不支持），请改选字体文件。',
        );
      }
      return;
    }
    final embedding = (report['embedding'] as Map?) ?? const {};
    if (embedding['outline_allowed'] != true) {
      update(
        () => message =
            '这个字体的授权标记不允许嵌入电子书（${_permissionText(embedding['permission'])}），请换一个字体。',
      );
      return;
    }
    final family = report['family'] as String? ?? origin ?? '未命名字体';
    final subset = embedding['subset_allowed'] == true;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _FontLicenseDialog(
        family: family,
        license: report['license_text'] as String?,
        bytes: report['bytes'] as int? ?? 0,
        subset: subset,
        origin: origin,
        missing: report['missing_count'] as int? ?? 0,
        missingSample: [
          for (final code in (report['missing_sample'] as List? ?? const []))
            if (int.tryParse('$code'.replaceFirst('U+', ''), radix: 16)
                case final value?)
              String.fromCharCode(value),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    String copied;
    try {
      // 复制一份：原文件挪走或改动后，书里的嵌入设置仍有效（授权按文件内容绑定）。
      copied = await fonts.keepFont(path, report['sha256'] as String);
    } catch (_) {
      update(() => message = '字体没有复制到程序数据目录，请检查磁盘空间后重试。');
      return;
    }
    fontFamily = family;
    await setFontResource({
      'path': copied,
      'face_index': report['face_index'] as int? ?? 0,
      'sha256': report['sha256'],
      'license_confirmed': true,
      if (!subset) 'mode': 'full',
    });
  }

  static String _permissionText(Object? permission) => switch (permission) {
    'restricted' => '禁止嵌入',
    'unknown' => '标记无法识别',
    _ => '$permission',
  };

  /// 当前嵌入字体的显示名：先用检查出的字体名，没有时用文件名。
  Future<void> loadFontFamily() async {
    final path = fontResource?['path'] as String?;
    final fonts = _fonts;
    if (path == null || fontFamily != null || fonts == null) return;
    try {
      final report = await fonts.inspectFont(path);
      if (mounted) update(() => fontFamily = report['family'] as String?);
    } catch (_) {
      // 读不了时显示文件名；转换时会报出具体问题。
    }
  }

  Widget fontControls() {
    final d = context.desk;
    final path = fontResource?['path'] as String?;
    final name = path == null ? null : fontFamily ?? paths.basename(path);
    final originals = [
      for (final f in _fonts?.originalFonts ?? const <Map<String, Object?>>[])
        if (const {'ttf', 'otf', 'ttc'}.contains(f['format']) ||
            (f['format'] == null &&
                RegExp(
                  r'\.(ttf|otf|ttc)$',
                  caseSensitive: false,
                ).hasMatch(f['path'] as String? ?? '')))
          f,
    ];
    final pick = widget.pickFont;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Row(
          children: [
            Text('嵌入字体', style: ui(12, w: 600, c: d.ink2)),
            const DeskHelp(
              '把字体放进书里，只保留书里用到的字（通常几百 KB 到几 MB）。'
              'Kindle 上在“Aa”里选“出版商字体”时显示这个字体，选别的字体时照常按阅读器字体。'
              '需要你有权在电子书中使用这个字体。原书自带的字体导入时已还原，可以直接选用。'
              '真机预览里选“出版商字体”可以看到效果。',
              key: ValueKey('layout-help-font'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                name ?? '不嵌入',
                key: const ValueKey('layout-font-name'),
                overflow: TextOverflow.ellipsis,
                style: ui(12.5, c: name == null ? d.ink3 : d.ink),
              ),
            ),
            DeskButton(
              name == null ? '选择字体文件…' : '更换…',
              key: const ValueKey('layout-font-pick'),
              quiet: true,
              onPressed: busy || pick == null
                  ? null
                  : () async {
                      final path = await pick();
                      if (path != null && mounted) await chooseFont(path);
                    },
            ),
            if (name != null)
              DeskButton(
                '不嵌入',
                key: const ValueKey('layout-font-remove'),
                quiet: true,
                onPressed: busy ? null : () => setFontResource(null),
              ),
          ],
        ),
        if (originals.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('原书自带的字体', style: ui(11.5, c: d.ink3)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (i, f) in originals.indexed)
                DeskButton(
                  _originalName(f),
                  key: ValueKey('layout-font-original-$i'),
                  quiet: true,
                  icon: Icons.font_download_outlined,
                  onPressed: busy
                      ? null
                      : () => chooseFont(
                          f['path'] as String,
                          origin: _originalName(f),
                        ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// 原书字体的显示名：原书里的文件名（去掉提取时加的序号）。
  static String _originalName(Map<String, Object?> f) {
    final href = (f['href'] as String? ?? f['path'] as String? ?? '')
        .replaceAll('\\', '/')
        .split('/')
        .last;
    return Uri.decodeComponent(
      href,
    ).replaceAll(RegExp(r'\.(ttf|otf|ttc|woff2?)$', caseSensitive: false), '');
  }
}

class _FontLicenseDialog extends StatelessWidget {
  const _FontLicenseDialog({
    required this.family,
    required this.license,
    required this.bytes,
    required this.subset,
    required this.origin,
    this.missing = 0,
    this.missingSample = const [],
  });
  final String family;
  final String? license;
  final int bytes;
  final bool subset;
  final String? origin;

  /// 书里用到、字体里没有的字（V123）：这些字按阅读器字体显示。
  final int missing;
  final List<String> missingSample;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final text = license?.trim() ?? '';
    return DeskAlert(
      title: Text('嵌入字体“$family”'),
      scrollable: true,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            subset
                ? '转换时只放入书里用到的字，成品会大一些（通常几百 KB 到几 MB）。'
                : '这个字体不允许裁剪，会整个放进书里（${(bytes / 1048576).toStringAsFixed(1)} MB），成品会明显变大。',
          ),
          const SizedBox(height: 8),
          Text(
            origin == null
                ? '字体有版权。请确认你有权把它嵌入电子书，例如免费商用字体或已购买嵌入授权。'
                : '这是原书自带的字体。请确认你有权在转换后的书里继续使用它。',
          ),
          if (missing > 0) ...[
            const SizedBox(height: 8),
            Text(
              '这个字体缺书里用到的 $missing 个字（如 ${missingSample.take(8).join(' ')}），这些字按阅读器字体显示。',
              key: const ValueKey('layout-font-missing'),
            ),
          ],
          if (text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('字体里写的授权说明：', style: ui(12, w: 600, c: d.ink2)),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 120),
              child: SingleChildScrollView(
                child: Text(text, style: ui(11.5, c: d.ink3, h: 1.5)),
              ),
            ),
          ],
        ],
      ),
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () => Navigator.pop(context, false),
        ),
        DeskButton(
          '我有权使用，嵌入',
          key: const ValueKey('layout-font-confirm'),
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
