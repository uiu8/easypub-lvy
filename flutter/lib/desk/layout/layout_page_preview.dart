// 排版页的阅读预览、阅读器设置、真机预览与按真机校准（R5-13 拆出，逻辑不变）。
part of 'layout_page.dart';

extension _LayoutPreviewSection on _LayoutPageState {
  Future<void> loadDevice() async {
    final store = session;
    if (store is! LayoutPreviewDeviceStore) return;
    try {
      final raw = await (store as LayoutPreviewDeviceStore).readPreviewDevice();
      if (!mounted || raw == null) return;
      device = PreviewDeviceChoice.decode(raw);
      customSize['width']!.text = '${device.width}';
      customSize['height']!.text = '${device.height}';
      customSize['ppi']!.text = '${device.ppi}';
      _previewRevision.value++;
    } catch (_) {}
  }

  void chooseDevice(PreviewDeviceChoice next) {
    device = next;
    previewPage = 0;
    _previewRevision.value++;
    final store = session;
    if (store is LayoutPreviewDeviceStore) {
      (store as LayoutPreviewDeviceStore)
          .savePreviewDevice(next.encode())
          .catchError((_) {});
    }
  }

  /// 按真机校准（LAY-096）：输入在真机当前设置下数到的每行字数与每页正文行数。
  Future<void> calibrate() async {
    final saved = device.calibrations[device.calibrationKey];
    final result = await showDialog<(int, int)?>(
      context: context,
      builder: (_) => _CalibrateDialog(device: device, initial: saved),
    );
    if (!mounted || result == null) return;
    final next = Map<String, (int, int)>.of(device.calibrations);
    if (result.$1 <= 0) {
      next.remove(device.calibrationKey);
    } else {
      next[device.calibrationKey] = result;
    }
    chooseDevice(device.copyWith(calibrations: next));
  }

  void applyCustomSize() {
    final w = int.tryParse(customSize['width']!.text.trim()) ?? 0;
    final h = int.tryParse(customSize['height']!.text.trim()) ?? 0;
    final ppi = int.tryParse(customSize['ppi']!.text.trim()) ?? 0;
    if (customKindleDevice(w, h, ppi) == null) {
      customError = '宽 320–5000、高 320–7000 像素，PPI 72–600。';
      _previewRevision.value++;
      return;
    }
    customError = '';
    chooseDevice(device.copyWith(id: 'custom', width: w, height: h, ppi: ppi));
  }

  Future<void> loadBody() async {
    try {
      final chapters = chapterSession ??= widget.library.openChapters(
        widget.bookId,
      );
      final page = chapters is ChapterOutlineSession
          ? await (chapters as ChapterOutlineSession).readOutline()
          : await chapters.read(0, includeBody: true);
      outline = page;
      final selected =
          page.nodes.where((node) => node.id == selectedChapter).firstOrNull ??
          page.nodes.where((node) => node.role == 'chapter').firstOrNull ??
          page.nodes.firstOrNull;
      selectedChapter = selected?.id;
      // 正文按块续读（每块约 30 行），预览最多取 400 行，避免只排出开头一小段。
      final lines = <String>[];
      final outputs = <int?>[];
      var more = false;
      if (selected != null) {
        var offset = 0;
        while (lines.length < 400) {
          final chunk = await chapters.body(page, selected.id, offset);
          if (!mounted) return;
          lines.addAll(chunk.lines);
          outputs.addAll(
            chunk.rows.length == chunk.lines.length
                ? chunk.rows.map((row) => row.outputLine)
                : List<int?>.filled(chunk.lines.length, null),
          );
          more = chunk.more;
          if (!chunk.more || chunk.lines.isEmpty) break;
          offset = chunk.offset + chunk.lines.length;
        }
      }
      final (images, head) = selected == null
          ? (const <int, List<PreviewImage>>{}, null)
          : await loadBodyImages(selected, outputs.take(400).toList());
      if (!mounted) {
        disposeBodyImages(images, head);
        return;
      }
      update(() {
        disposeBodyImages(bodyImages, chapterHeadOverride);
        bodyImages = images;
        chapterHeadOverride = head;
        chapterTitle = selected?.title ?? '正文';
        bodyError = '';
        body = lines.take(400).join('\n');
        bodyPartial = more || lines.length > 400;
        if (body.length > 40000) {
          body = body.substring(0, 40000);
          bodyPartial = true;
        }
        previewPage = 0;
        if (body.isEmpty) bodyError = '此章节没有可预览正文。';
      });
    } catch (_) {
      if (mounted) update(() => bodyError = '正文读取失败，请重新进入排版页。');
    } finally {
      if (mounted) update(() => loading = false);
    }
  }

  /// 读本章的正文插图（R5-01）：按插图在成品里的行号对到正文行，读不出位置或图片时
  /// 照样返回（图片画成虚线框），读不出插图列表时返回空表，不影响正文预览。
  Future<(Map<int, List<PreviewImage>>, PreviewImage?)> loadBodyImages(
    ChapterNode node,
    List<int?> outputs,
  ) async {
    final resources = widget.library.openResources(widget.bookId);
    final result = <int, List<PreviewImage>>{};
    PreviewImage? head;
    try {
      if (resources is! ResourceLocator) return (result, null);
      final locations = await (resources as ResourceLocator).locateAll();
      for (final item in await resources.read()) {
        if (item.index < 0 || item.index >= locations.length) continue;
        final at = locations[item.index];
        final line = at.outputLine;
        if (at.nodeId != node.id || line == null) continue;
        final after = line == node.line ? -1 : outputs.indexOf(line);
        if (after == -1 && line != node.line) continue;
        dui.Image? pixels;
        double? natural;
        try {
          // 先读原图宽度（随正文插图按原尺寸显示），大图缩到 900 宽再解码。
          final buffer = await dui.ImmutableBuffer.fromUint8List(
            await readLocalFileBytes(item.path),
          );
          final descriptor = await dui.ImageDescriptor.encoded(buffer);
          natural = descriptor.width.toDouble();
          final codec = await descriptor.instantiateCodec(
            targetWidth: math.min(descriptor.width, 900),
          );
          pixels = (await codec.getNextFrame()).image;
          codec.dispose();
          descriptor.dispose();
          buffer.dispose();
        } catch (_) {
          pixels = null;
        }
        final image = PreviewImage(
          item.name,
          pixels: pixels,
          naturalWidth: natural,
          layout: item.layout,
          caption: item.caption,
        );
        if (item.layout == 'chapter_head' && head == null) {
          head = image;
        } else {
          (result[after] ??= []).add(image);
        }
      }
    } catch (_) {
      // 插图只是预览的补充，读不出时只预览正文。
    } finally {
      resources.dispose();
    }
    return (result, head);
  }

  void disposeBodyImages(
    Map<int, List<PreviewImage>> images,
    PreviewImage? head,
  ) {
    for (final list in images.values) {
      for (final image in list) {
        image.pixels?.dispose();
      }
    }
    head?.pixels?.dispose();
  }

  Future<void> generatePreview() async {
    if (generatingPreview || session is! LayoutPublicationPreviewSession) {
      return;
    }
    update(() => generatingPreview = true);
    try {
      await save();
      if (identity != baseline) throw const FormatException('请先补全排版数值。');
      final service = session as LayoutPublicationPreviewSession;
      final generated = await service.renderPreview(entryId: selectedChapter);
      await service.openPreview(generated);
      if (mounted) {
        update(() => message = '已在浏览器打开实际生成内容，使用本书 XHTML、CSS 和资源。');
      }
    } catch (error) {
      if (mounted) {
        update(() => message = deskErrorText(error, '实际预览生成失败，请检查本书资源后重试。'));
      }
    } finally {
      if (mounted) update(() => generatingPreview = false);
    }
  }

  Future<void> openKindlePreview() async {
    if (session is! LayoutDraftPreviewSession) return;
    final host = widget.kindlePreview;
    final edge = host.findEdge();
    final plugin = host.findPlugin();
    if (edge == null || plugin == null) {
      update(
        () => message = edge == null
            ? '没有找到 Microsoft Edge，无法打开真机预览。'
            : '没有找到真机预览组件（plugins/kindle-preview），请检查程序目录是否完整。',
      );
      return;
    }
    try {
      final server = _kindle ??= KindlePreviewServer(
        pluginDirectory: plugin,
        state: _kindleState,
        render: _kindleRender,
        metrics: _kindleMetrics,
        apply: _kindleApply,
        fontDirectory: paths.join(
          StorageLocations.directory('settings'),
          'preview-fonts',
        ),
      );
      await host.launch(edge, await server.start());
      if (mounted) update(() => message = '已在独立窗口打开真机预览。');
    } catch (_) {
      if (mounted) update(() => message = '真机预览没有打开，请重试。');
    }
  }

  Map<String, Object?> _kindleDevice(KindleDevice k) => {
    'id': k.id,
    'name': kindleShortName(k.name),
    'width': k.width,
    'height': k.height,
    'ppi': k.ppi,
    'viewportWidth': k.viewportWidth,
    'viewportHeight': k.viewportHeight,
    'bodyWidthMm': k.bodyWidthMm,
    'bodyHeightMm': k.bodyHeightMm,
    'grip': k.grip,
    'gripLeft': k.gripLeft,
    'topBezelMm': k.topBezelMm,
    'cornerMm': k.cornerMm,
    'logo': k.logo,
    'pressMarks': k.pressMarks,
  };

  /// 真机预览送来的样式包设置（V76）：返回去掉这两个键后的排版值，以及对应的样式包（null 为停用）。
  (Map<String, Object?>, Map<String, dynamic>?) _kindleStyle(
    Map<String, Object?> draft,
  ) {
    final rest = Map<String, Object?>.from(draft);
    // 系统提示预设（V77）：换成对应参数；custom 表示不改。
    final note = rest.remove('system_note_preset');
    final panel = rest.remove('system_panel_preset');
    if (blockStylePresets.containsKey(note) ||
        blockStylePresets.containsKey(panel)) {
      final base = Map<String, dynamic>.from(
        (rest['system_styles'] as Map?) ??
            systemStyles ??
            defaultSystemStyles(),
      );
      if (notePresetNames.containsKey(note)) {
        base['note'] = blockStylePresets[note]!;
      }
      if (panelPresetNames.containsKey(panel)) {
        base['panel'] = blockStylePresets[panel]!;
      }
      rest['system_styles'] = base;
    }
    final on = rest.remove('chapter_style_on');
    final frame = rest.remove('chapter_style_volume_frame');
    final style = chapterStyle;
    if (style == null || on == 'off') return (rest, null);
    return (
      rest,
      {
        ...style,
        if (frame is String && volumeFrames.containsKey(frame))
          'volume_frame': frame,
      },
    );
  }

  Future<LayoutDraftPreview> _kindleRender(
    Map<String, Object?> draft,
    String? entry,
  ) {
    final current = session;
    if (!mounted || current is! LayoutDraftPreviewSession) {
      throw const FormatException('排版页已关闭。');
    }
    final (rest, style) = _kindleStyle(draft);
    return (current as LayoutDraftPreviewSession).renderDraftPreview({
      for (final e in values.entries)
        if (e.value != null) e.key: e.value,
      ...rest,
      if (chapterStyle != null) 'chapter_style': style,
    }, entryId: entry ?? selectedChapter);
  }

  Future<String?> _kindleApply(Map<String, Object?> request) async {
    if (!mounted || session == null) return '排版页已关闭。';
    if (busy) return '排版页正在处理，请稍后再试。';
    final styled =
        request.containsKey('chapter_style_on') ||
        request.containsKey('chapter_style_volume_frame');
    final (draft, style) = _kindleStyle(request);
    if (draft.keys.any((key) => !layoutFields.contains(key))) {
      return '只能写回排版字段。';
    }
    // 样式包（V76）：与排版页“章节样式包”同一条应用路径，进变更记录。
    if (styled && chapterStyle != null) {
      final before = chapterStyle;
      await setChapterStyle(style, style == null ? '已停用样式包' : '已更新样式包');
      if (!mounted) return '排版页已关闭。';
      if (chapterStyle == before) return '样式包未能写回，请在排版页查看原因。';
      if (draft.isEmpty) return null;
    }
    edit(() {
      for (final e in draft.entries) {
        final value = e.value;
        switch (e.key) {
          case 'text_alignment':
            if (value is String) alignment = value;
          case 'writing_mode':
            if (value is String) writingMode = value;
          case 'vertical_digits':
            if (value is num) verticalDigits = value.toInt();
          case 'heading_style':
            if (value is String && headingStyles.containsKey(value)) {
              headingStyle = value;
            }
          case 'scene_break_style':
            if (value is String && sceneBreakStyles.containsKey(value)) {
              sceneBreakStyle = value;
            }
          case 'first_paragraph_style':
            if (value is String && firstParagraphStyles.containsKey(value)) {
              firstParagraphStyle = value;
            }
          case 'rare_char_ruby':
            if (value is String && rareCharRubyModes.containsKey(value)) {
              rareCharRuby = value;
            }
          case 'rare_char_scope':
            if (value is String && rareCharScopes.containsKey(value)) {
              rareCharScope = value;
            }
          case 'chat_block_style':
            if (value is String && chatBlockStyles.containsKey(value)) {
              chatBlockStyle = value;
            }
          case 'letter_block_style':
            if (value is String && letterBlockStyles.containsKey(value)) {
              letterBlockStyle = value;
            }
          case 'inset_font':
            if (value is String && insetFonts.containsKey(value)) {
              insetFont = value;
            }
          case 'inset_detect':
            if (value is String && insetDetectModes.containsKey(value)) {
              insetDetect = value;
            }
          case 'inset_styles':
            if (value == null || value is Map) {
              insetStyles = (value as Map?)?.cast<String, dynamic>();
            }
          case 'chapter_head_scope':
            if (value is String && chapterHeadScopes.containsKey(value)) {
              chapterHeadScope = value;
            }
          case 'chapter_head_width':
            if (value is String && chapterHeadWidths.containsKey(value)) {
              chapterHeadWidth = value;
            }
          case 'system_block_style':
            if (value is String && systemBlockStyles.containsKey(value)) {
              systemBlockStyle = value;
            }
          case 'system_styles':
            if (value == null || value is Map) {
              systemStyles = (value as Map?)?.cast<String, dynamic>();
            }
          case 'verse_block_style':
            if (value is String && verseBlockStyles.containsKey(value)) {
              verseBlockStyle = value;
            }
          case 'note_style':
            if (value is String && noteStyles.containsKey(value)) {
              noteStyle = value;
            }
          default:
            final controller = numbers[e.key];
            if (controller != null && value is num) {
              controller.text = e.key == 'fullwidth_indent'
                  ? '${value.toInt()}'
                  : '${value.toDouble()}';
            } else if (value is bool && flags.containsKey(e.key)) {
              flags[e.key] = value;
            } else if (value is String && units.containsKey(e.key)) {
              units[e.key] = value;
            }
        }
      }
    });
    await save();
    if (!mounted) return '排版页已关闭。';
    return identity == baseline ? null : '没有写回：$message';
  }

  Widget reading() {
    final d = context.desk;
    // 书页模拟 Kindle 白纸，不随软件主题变（V79）：纸色与字色固定取宣纸令牌。
    const page = Desk.light;
    if (loading) return const Center(child: CircularProgressIndicator());
    // 字号与行高按机型和阅读器设置换算（LAY-096）：书内字号以 110% 为基准缩放。
    final metrics = readerMetrics(
      device,
      bookScale:
          (units['font_size_unit'] == '%'
                  ? number('font_size', 110) / 110
                  : number('font_size', 18) / 17.6)
              .clamp(.3, 4.0),
      bookLineHeight: number('line_height', 1.2).clamp(1, 2.3),
    );
    final size = metrics.fontPx.clamp(6.0, 96.0);
    TextStyle face(double s, {FontWeight? w}) => device.serif
        ? serif(s, w: w == null ? 400 : 650, c: page.ink, h: metrics.lineRatio)
        : ui(s, w: w == null ? 400 : 650, c: page.ink, h: metrics.lineRatio);
    double margin(String side) =>
        (number('margin_$side', 0) *
                (units['margin_${side}_unit'] == 'em' ? size : 1))
            .clamp(0.0, 120.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 预览设置收成一行（LAY-098）：章节、机型、阅读器设置（弹出面板）、实测 / 推算、实际生成预览。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (outline != null && outline!.nodes.isNotEmpty)
                SizedBox(
                  width: narrowPreview ? 170 : 220,
                  child: DeskChoice<String>(
                    value: selectedChapter,
                    decoration: deskInput(context).copyWith(labelText: '预览章节'),
                    searchable: true,
                    items: [
                      for (final node in outline!.nodes)
                        DropdownMenuItem(
                          value: node.id,
                          child: Text(
                            node.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: generatingPreview
                        ? null
                        : (value) {
                            update(() {
                              selectedChapter = value;
                              loading = true;
                            });
                            loadBody();
                          },
                  ),
                ),
              Tooltip(
                message:
                    '${device.device.name}\n${device.device.width} × ${device.device.height} · ${device.device.ppi} PPI',
                child: SizedBox(
                  width: 160,
                  child: DeskChoice<String>(
                    key: const ValueKey('layout-preview-device'),
                    value: device.id,
                    isExpanded: true,
                    // 选择框只写短名，菜单与悬停提示写全名（LAY-102）。
                    selectedLabel: (id) => Text(
                      kindleShortName(
                        kindleDevices
                                .where((k) => k.id == id)
                                .firstOrNull
                                ?.name ??
                            device.device.name,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    decoration: deskInput(context).copyWith(labelText: '预览机型'),
                    items: [
                      for (final k in kindleDevices)
                        DropdownMenuItem(
                          value: k.id,
                          child: Text(
                            k.name.split('（').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const DropdownMenuItem(
                        value: 'custom',
                        child: Text('自定义分辨率…'),
                      ),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      if (id == 'custom') {
                        applyCustomSize();
                      } else {
                        chooseDevice(device.copyWith(id: id));
                      }
                    },
                  ),
                ),
              ),
              readerMenu(metrics),
              Tooltip(
                message: metrics.measured ? '与真机照片或你的校准一致' : '只有 KPW5 的 4、8、12 档（窄边距、中行距、书内 110% / 1.2）是实测；其余按 Kindle 固件的字号表与页边距推算，可“按真机校准”',
                child: DeskTag(
                  metrics.note,
                  metrics.measured ? Tone.ok : Tone.warn,
                ),
              ),
              if (session is LayoutDraftPreviewSession)
                iconOnlyPreview
                    ? IconButton(
                        key: const ValueKey('layout-kindle-preview'),
                        tooltip: '真机预览：在独立窗口按机身尺寸显示实际生成内容',
                        icon: const Icon(Icons.tablet_android_outlined),
                        onPressed: busy ? null : openKindlePreview,
                      )
                    : DeskButton(
                        '真机预览',
                        key: const ValueKey('layout-kindle-preview'),
                        icon: Icons.tablet_android_outlined,
                        tooltip: '在独立窗口按机身尺寸显示实际生成内容，可调排版并写回',
                        onPressed: busy ? null : openKindlePreview,
                      ),
              if (session is LayoutPublicationPreviewSession)
                iconOnlyPreview
                    // 预览区较窄时只留图标，避免设置行折成两行（LAY-100、LAY-102）。
                    ? IconButton(
                        key: const ValueKey('layout-real-preview-icon'),
                        tooltip: '实际生成预览：用浏览器查看实际生成的 XHTML / CSS',
                        icon: const Icon(Icons.open_in_browser_rounded),
                        onPressed: busy || generatingPreview
                            ? null
                            : generatePreview,
                      )
                    : DeskButton(
                        '实际生成预览',
                        icon: Icons.open_in_browser_rounded,
                        busy: generatingPreview,
                        tooltip: '用浏览器查看实际生成的 XHTML / CSS',
                        onPressed: busy || generatingPreview
                            ? null
                            : generatePreview,
                      ),
              DeskHelp(
                '近似分页，以真机为准；不渲染附加 CSS，插图按版心宽度近似画出。实际生成预览在浏览器打开。'
                '${bodyPartial ? '\n本章较长，只预览开头一部分。' : ''}',
              ),
            ],
          ),
          if (device.id == 'custom') ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (key, hint) in const [
                  ('width', '宽'),
                  ('height', '高'),
                  ('ppi', 'PPI'),
                ])
                  SizedBox(
                    width: 84,
                    child: TextField(
                      key: ValueKey('layout-preview-$key'),
                      controller: customSize[key],
                      keyboardType: TextInputType.number,
                      style: mono(12.5, c: d.ink),
                      decoration: deskInput(context).copyWith(labelText: hint),
                      onSubmitted: (_) => applyCustomSize(),
                    ),
                  ),
                DeskButton('更新', quiet: true, onPressed: applyCustomSize),
                if (customError.isNotEmpty)
                  Text(customError, style: ui(11.5, c: d.pen)),
              ],
            ),
          ],
          if (writingMode == 'vertical' &&
              session is LayoutDraftPreviewSession) ...[
            const SizedBox(height: 8),
            Row(
              key: const ValueKey('layout-vertical-hint'),
              children: [
                Expanded(
                  child: Text(
                    '竖排书：这里按横排近似显示，竖排、注音与着重号请在真机预览中查看。',
                    style: ui(12, c: d.ink2),
                  ),
                ),
                DeskButton(
                  '打开真机预览',
                  quiet: true,
                  onPressed: busy ? null : openKindlePreview,
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: bodyError.isNotEmpty
                ? Center(
                    child: Text(bodyError, style: ui(13, c: d.ink2)),
                  )
                : LayoutBuilder(
                    builder: (context, box) {
                      final k = device.device;
                      final pageSize = Size(
                        k.viewportWidth.toDouble(),
                        k.viewportHeight.toDouble(),
                      );
                      // 章节标题按所选样式画（V36，LAY-117）。
                      final look =
                          headingLooks[headingStyle] ??
                          headingLooks['classic']!;
                      final titleFace = look.sans
                          ? ui(
                              size * look.scale,
                              w: 700,
                              c: page.ink,
                              h: metrics.lineRatio,
                            )
                          : face(size * look.scale, w: FontWeight.w700);
                      final style = PreviewStyle(
                        title: titleFace,
                        heading: look,
                        sceneBreak: sceneBreakStyle,
                        firstParagraph: firstParagraphStyle,
                        // 资源页把某张插图设为“章首图”时，这一章用它代替统一章首图（R5-01）。
                        headImage:
                            chapterHeadOverride?.pixels ??
                            (chapterHeadScope == 'volume'
                                ? null
                                : chapterHeadPixels),
                        headFraction: switch (chapterHeadWidth) {
                          'third' => 1 / 3,
                          'full' => 1.0,
                          _ => .5,
                        },
                        systemBlock: systemBlockStyle,
                        systemStyles: systemBlockStyle == 'styled'
                            ? (systemStyles ?? defaultSystemStyles())
                            : null,
                        verseBlock: verseBlockStyle,
                        ruleScale: size / 17.6,
                        body: face(size),
                        align: switch (alignment) {
                          'start' => TextAlign.start,
                          'left' => TextAlign.left,
                          'center' => TextAlign.center,
                          'right' => TextAlign.right,
                          _ => TextAlign.justify,
                        },
                        indent:
                            number('paragraph_indent', 2).clamp(0, 6) * size,
                        paragraphSpacing:
                            number('paragraph_spacing', .5).clamp(0, 6) * size,
                        titleSpacing: 20,
                        padding:
                            metrics.padding +
                            EdgeInsets.fromLTRB(
                              margin('left'),
                              margin('top'),
                              margin('right'),
                              margin('bottom'),
                            ),
                      );
                      final fullwidth = number(
                        'fullwidth_indent',
                        0,
                      ).clamp(0, 8).toInt();
                      final key = [
                        device.encode(),
                        k.viewportWidth,
                        k.viewportHeight,
                        identity,
                        chapterTitle,
                        body.length,
                        body.hashCode,
                        identityHashCode(bodyImages),
                        identityHashCode(chapterHeadOverride),
                        systemScope,
                      ].join('|');
                      if (key != _pagesKey) {
                        _pagesKey = key;
                        // 去掉空行时段落序号会变：插图按原来的正文行换算到段落序号（R5-01）。
                        final paragraphs = <String>[];
                        final images = <int, List<PreviewImage>>{
                          if (bodyImages[-1] != null) -1: bodyImages[-1]!,
                        };
                        for (final (line, paragraph)
                            in body.split('\n').indexed) {
                          if (flags['remove_blank_lines'] != true ||
                              paragraph.trim().isNotEmpty) {
                            paragraphs.add(
                              paragraph.trim().isNotEmpty && fullwidth > 0
                                  ? '${'　' * fullwidth}${paragraph.replaceFirst(RegExp(r'^[ 　\t]+'), '')}'
                                  : paragraph,
                            );
                          }
                          final here = bodyImages[line];
                          if (here != null) {
                            (images[paragraphs.length - 1] ??= []).addAll(here);
                          }
                        }
                        _pages = paginatePreview(
                          title: chapterTitle,
                          paragraphs: paragraphs,
                          style: style,
                          page: pageSize,
                          locale: Localizations.maybeLocaleOf(context),
                          images: images,
                          systemScope: systemScope,
                        );
                      }
                      final index = previewPage.clamp(0, _pages.length - 1);
                      return Column(
                        children: [
                          // 按剩余空间等比放大（LAY-099）：SizedBox.expand 给出紧约束，
                          // FittedBox 才会放大；原来的 Center 只给松约束，只会缩小。
                          Expanded(
                            // 滚轮在预览上翻页（LAY-101）：向下下一页，向上上一页。
                            child: Listener(
                              key: const ValueKey('layout-preview-wheel'),
                              onPointerSignal: (event) {
                                if (event is! PointerScrollEvent) return;
                                final now = DateTime.now();
                                // 触控板一次滑动会连发很多事件：间隔太近的只算一次。
                                if (now.difference(_lastWheel) <
                                    const Duration(milliseconds: 220)) {
                                  return;
                                }
                                final next = event.scrollDelta.dy > 0
                                    ? index + 1
                                    : event.scrollDelta.dy < 0
                                    ? index - 1
                                    : index;
                                if (next == index ||
                                    next < 0 ||
                                    next >= _pages.length) {
                                  return;
                                }
                                _lastWheel = now;
                                previewPage = next;
                                _previewRevision.value++;
                              },
                              child: SizedBox.expand(
                                child: FittedBox(
                                  child: Container(
                                    key: const ValueKey('layout-preview-page'),
                                    decoration: BoxDecoration(
                                      color: page.paper,
                                      boxShadow: d.shadow2,
                                      border: Border.all(color: d.line),
                                    ),
                                    child: PreviewPage(
                                      pieces: _pages[index],
                                      style: style,
                                      size: pageSize,
                                      paper: page.paper,
                                      locale: Localizations.maybeLocaleOf(
                                        context,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              DeskButton(
                                '上一页',
                                icon: Icons.chevron_left_rounded,
                                quiet: true,
                                onPressed: index == 0
                                    ? null
                                    : () {
                                        previewPage = index - 1;
                                        _previewRevision.value++;
                                      },
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Text(
                                  '第 ${index + 1} / ${_pages.length} 页',
                                  key: const ValueKey('layout-preview-pages'),
                                  style: ui(12, c: d.ink2),
                                ),
                              ),
                              DeskButton(
                                '下一页',
                                icon: Icons.chevron_right_rounded,
                                quiet: true,
                                onPressed: index + 1 >= _pages.length
                                    ? null
                                    : () {
                                        previewPage = index + 1;
                                        _previewRevision.value++;
                                      },
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 阅读器设置弹出面板（LAY-096/098）：字号档位、页边距、行距、字体与按真机校准，
  /// 收起时按钮上显示当前设置，不再占用预览上方的空间。
  Widget readerMenu(ReaderMetrics metrics) {
    final d = context.desk;
    const margins = {'narrow': '窄', 'medium': '中', 'wide': '宽'};
    const spacings = {'small': '小', 'medium': '中', 'large': '大'};
    final summary =
        '字号 ${device.level} · ${margins[device.margin]}边距 · ${spacings[device.spacing]}行距 · ${device.serif ? '衬线' : '无衬线'}';
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: ui(12, c: d.ink3)),
          ),
          Flexible(child: child),
        ],
      ),
    );
    return MenuAnchor(
      controller: readerMenuController,
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        Padding(
          key: const ValueKey('layout-reader-panel'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: SizedBox(
            width: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                row(
                  '字号',
                  Row(
                    children: [
                      IconButton(
                        tooltip: '小一档',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.remove_rounded, size: 18),
                        onPressed: device.level <= 1
                            ? null
                            : () => chooseDevice(
                                device.copyWith(level: device.level - 1),
                              ),
                      ),
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${device.level}',
                          key: const ValueKey('layout-reader-level'),
                          textAlign: TextAlign.center,
                          style: mono(13, c: d.ink),
                        ),
                      ),
                      IconButton(
                        tooltip: '大一档',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        onPressed: device.level >= 14
                            ? null
                            : () => chooseDevice(
                                device.copyWith(level: device.level + 1),
                              ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '档位 1–14',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(11.5, c: d.ink3),
                        ),
                      ),
                    ],
                  ),
                ),
                row(
                  '页边距',
                  DeskSegmented<String>(
                    value: device.margin,
                    options: margins,
                    onChanged: (v) => chooseDevice(device.copyWith(margin: v)),
                  ),
                ),
                row(
                  '行距',
                  DeskSegmented<String>(
                    value: device.spacing,
                    options: spacings,
                    onChanged: (v) => chooseDevice(device.copyWith(spacing: v)),
                  ),
                ),
                row(
                  '字体',
                  DeskSegmented<bool>(
                    value: device.serif,
                    options: const {false: '无衬线', true: '衬线'},
                    onChanged: (v) => chooseDevice(device.copyWith(serif: v)),
                  ),
                ),
                Divider(height: 1, color: d.line),
                const SizedBox(height: 10),
                Text(
                  metrics.measured ? '当前设置与真机照片或你的校准一致。' : '只有 KPW5 的 4、8、12 档（窄边距、中行距、书内 110% / 1.2）是实测，其余按 Kindle 固件的字号表与页边距推算。',
                  style: ui(11.5, c: d.ink2, h: 1.5),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DeskButton(
                    '按真机校准…',
                    key: const ValueKey('layout-reader-calibrate'),
                    icon: Icons.straighten_rounded,
                    quiet: true,
                    onPressed: () {
                      readerMenuController.close();
                      calibrate();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      child: DeskButton(
        // 预览区较窄时只写字号，完整设置在悬停提示里，预览设置保持一行（LAY-102）。
        narrowPreview ? '字号 ${device.level} …' : summary,
        key: const ValueKey('layout-reader-settings'),
        icon: Icons.tune_rounded,
        tooltip: narrowPreview
            ? '$summary\nKindle 阅读器设置：字号、页边距、行距、字体与按真机校准'
            : 'Kindle 阅读器设置：字号、页边距、行距、字体与按真机校准',
        onPressed: () => readerMenuController.isOpen
            ? readerMenuController.close()
            : readerMenuController.open(),
      ),
    );
  }
}

/// 按真机校准：在 Kindle 上用与当前预览相同的字号、页边距、行距，数一行的字数和一页正文的行数。
class _CalibrateDialog extends StatefulWidget {
  const _CalibrateDialog({required this.device, this.initial});
  final PreviewDeviceChoice device;
  final (int, int)? initial;
  @override
  State<_CalibrateDialog> createState() => _CalibrateDialogState();
}

class _CalibrateDialogState extends State<_CalibrateDialog> {
  late final perLine = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial!.$1}',
  );
  late final perPage = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial!.$2}',
  );
  String error = '';

  @override
  void dispose() {
    perLine.dispose();
    perPage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final c = widget.device;
    const margins = {'narrow': '窄', 'medium': '中', 'wide': '宽'};
    const spacings = {'small': '小', 'medium': '中', 'large': '大'};
    Widget field(String label, TextEditingController controller, Key key) =>
        Expanded(
          child: TextField(
            key: key,
            controller: controller,
            keyboardType: TextInputType.number,
            style: mono(13, c: d.ink),
            decoration: deskInput(context).copyWith(labelText: label),
          ),
        );
    return DeskDialog(
      title: '按真机校准',
      subtitle:
          '${c.device.name} · 字号 ${c.level} · 页边距${margins[c.margin]} · 行距${spacings[c.spacing]}',
      closeTooltip: '取消校准',
      width: 520,
      actions: [
        if (widget.initial != null)
          DeskButton(
            '清除这条校准',
            quiet: true,
            onPressed: () => Navigator.pop(context, (0, 0)),
          ),
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          '保存校准',
          key: const ValueKey('calibrate-save'),
          primary: true,
          onPressed: () {
            final a = int.tryParse(perLine.text.trim()) ?? 0;
            final b = int.tryParse(perPage.text.trim()) ?? 0;
            if (a < 4 || a > 80 || b < 3 || b > 80) {
              setState(() => error = '每行字数填 4–80，每页行数填 3–80。');
              return;
            }
            Navigator.pop(context, (a, b));
          },
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '在 Kindle 上打开同一本书，设成与上面相同的字号、页边距和行距；数一行满行的字数（不含段首缩进），'
            '再数一页正文共有几行（含段落之间的行）。保存后，这台机型在这组设置下按你的数字排版。',
            style: ui(12.5, c: d.ink2, h: 1.55),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              field('每行字数', perLine, const ValueKey('calibrate-line')),
              const SizedBox(width: 10),
              field('每页行数', perPage, const ValueKey('calibrate-page')),
            ],
          ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(error, style: ui(12, c: d.pen)),
          ],
        ],
      ),
    );
  }
}
