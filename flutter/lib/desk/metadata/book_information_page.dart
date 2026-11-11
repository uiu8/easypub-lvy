// 书籍信息：左侧基本信息与系列分类（停顿自动应用，不合法输入只暂存），右侧封面预览、
// 适配与封面入口。保存、草稿、离开保护的逻辑逐行沿用早先的 BookInformationPage。
import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../checks/check_board.dart';

import 'package:go_router/go_router.dart';

import '../errors.dart';

import '../../application/book_information_service.dart';
import '../../application/library_service.dart';
import '../../application/supplemental_page_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import '../page_parts.dart' show DeskPageTitle;
import '../widgets.dart';
import 'cover_editor_page.dart';
import 'cover_drop.dart';
import 'cover_image_dialog.dart';
import 'cover_preview.dart';
import 'supplemental_pages_card.dart';

class InformationNavigationGuard {
  Future<bool> Function()? check;
  Future<bool> canLeave() async => await check?.call() ?? true;
}

class BookInformationPage extends StatefulWidget {
  const BookInformationPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.navigation,
    required this.pickImage,
    this.onEditorChanged,
    this.initialCoverAction,
    this.initialFocus,
  });
  final LibraryService library;
  final String bookId;
  final InformationNavigationGuard navigation;
  final Future<String?> Function() pickImage;
  final ValueChanged<bool>? onEditorChanged;
  final String? initialCoverAction;

  /// 从检查过来：要补的字段（title / author / language / cover）。
  final String? initialFocus;
  @override
  State<BookInformationPage> createState() => _BookInformationPageState();
}

class _BookInformationPageState extends State<BookInformationPage> {
  BookInformationSession? session;
  final controllers = <String, TextEditingController>{};

  /// 检查指到的字段：标出来并把光标放进去，改了就不再标。
  late String? focusField = widget.initialFocus;
  final fieldKeys = <String, GlobalKey>{};
  final fieldFocus = <String, FocusNode>{};
  CheckBoard? board;

  static const fieldProblems = {
    'title': '书名尚未填写',
    'author': '作者尚未填写',
    'language': '书籍语言尚未明确',
    'cover': '尚未指定封面',
  };

  void showField(String field) {
    if (!mounted) return;
    setState(() => focusField = field);
    if (field == 'cover') pane = 1;
    board?.noteField(field);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      fieldFocus[field]?.requestFocus();
      final target = fieldKeys[field]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: .3,
          duration: const Duration(milliseconds: 160),
        );
      }
    });
  }

  Map<String, Object?> baseline = {};
  final touchedFields = <String>{};
  String? cover;
  String fit = 'contain', message = '';
  Object? crop;
  Map<String, dynamic>? design;
  bool busy = false, adjusting = false, generating = false;
  Timer? _saveTimer;
  Future<void>? _saving;
  WorkspaceAutosaveService? get autosave =>
      widget.library is WorkspaceAutosaveService
      ? widget.library as WorkspaceAutosaveService
      : null;
  String get draftKey => 'metadata:${widget.bookId}';
  void rememberDraft() => autosave?.writeDraft(draftKey, {
    'values': values,
    'touched': touchedFields.toList(),
  });
  void changed() {
    rememberDraft();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), save);
  }

  void restoreDraft() {
    final stored = autosave?.readDraft(draftKey);
    final draft = stored?['values'] as Map?;
    if (draft == null) return;
    for (final entry in controllers.entries) {
      if (draft.containsKey(entry.key)) {
        entry.value.text = draft[entry.key] as String;
      }
    }
    cover = draft['cover_path'] as String?;
    fit = draft['cover_fit'] as String? ?? fit;
    crop = draft['cover_crop'];
    design = (draft['cover_design'] as Map?)?.cast<String, dynamic>();
    touchedFields.addAll(
      (stored?['touched'] as List? ?? const []).cast<String>(),
    );
    message = '已恢复上次编辑的内容';
  }

  Map<String, Object?> get values => {
    for (final entry in controllers.entries) entry.key: entry.value.text,
    'cover_path': cover,
    'cover_fit': fit,
    'cover_crop': crop,
    'cover_design': design,
  };
  bool get dirty =>
      touchedFields.isNotEmpty || !deskDeepEquals(values, baseline);
  @override
  void initState() {
    super.initState();
    widget.navigation.check = canLeave;
    try {
      session = widget.library.openBookInformation(widget.bookId);
      load();
      restoreDraft();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || session == null) return;
        board = CheckBoardScope.maybeOf(context)?..attachField(showField);
        if (widget.initialFocus case final field?) showField(field);
        if (dirty) changed();
        if (widget.initialCoverAction == 'select') {
          chooseImage();
        } else if (widget.initialCoverAction == 'generate') {
          openCoverEditor(textCover: true);
        }
      });
    } catch (_) {
      message = '先选择或导入一本书，再编辑书籍信息。';
    }
  }

  void load() {
    final saved = session!.saved;
    for (final key in bookInformationFields.keys) {
      controllers.putIfAbsent(key, () => TextEditingController()).text =
          saved[key] as String? ?? '';
    }
    cover = saved['cover_path'] as String?;
    fit = saved['cover_fit'] as String? ?? 'contain';
    crop = saved['cover_crop'];
    design = (saved['cover_design'] as Map?)?.cast<String, dynamic>();
    baseline = values;
    touchedFields.clear();
  }

  @override
  void dispose() {
    board?.detachField(showField);
    for (final node in fieldFocus.values) {
      node.dispose();
    }
    widget.navigation.check = null;
    _saveTimer?.cancel();
    for (final controller in controllers.values) {
      controller.dispose();
    }
    session?.dispose();
    super.dispose();
  }

  Future<bool> canLeave() async {
    _saveTimer?.cancel();
    if (session != null) {
      if (dirty) rememberDraft();
      await save();
      if (dirty) await save();
    }
    return await autosave?.flushWorkspace() ?? !busy;
  }

  /// 拖入的图片（后，用户反馈）：与“选择图片”同一流程，预先核验这张图。
  bool dropHover = false;
  Future<void> dropImage(DropDoneDetails details) async {
    setState(() => dropHover = false);
    final image = details.files
        .map((f) => f.path)
        .where(isCoverImagePath)
        .firstOrNull;
    if (image == null) {
      if (details.files.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          deskSnackBar(content: const Text('这里只接受图片：PNG、JPEG、WebP、GIF 或 BMP。')),
        );
      }
      return;
    }
    await chooseImage(initialPath: image);
  }

  Future<void> chooseImage({String? initialPath}) async {
    _saveTimer?.cancel();
    await save();
    if (dirty) await save();
    _saveTimer?.cancel();
    if (!mounted) return;
    final choice = await showDialog<CoverImageChoice>(
      context: context,
      builder: (_) => CoverImageDialog(
        session: session!,
        pickImage: widget.pickImage,
        initialFit: fit,
        autosave: autosave,
        draftKey: 'cover-image:${widget.bookId}',
        initialPath: initialPath,
      ),
    );
    if (mounted && choice != null) {
      setState(() {
        cover = choice.evidence.path;
        design = null;
        adjusting = false;
        fit = choice.fit;
        crop = null;
        message = '';
      });
      changed();
      if (choice.adjust) await openCoverEditor(textCover: false);
    }
  }

  Future<void> openCoverEditor({required bool textCover}) async {
    _saveTimer?.cancel();
    await save();
    if (dirty) await save();
    _saveTimer?.cancel();
    if (!mounted) return;
    setState(() {
      generating = textCover;
      adjusting = !textCover;
    });
    widget.onEditorChanged?.call(true);
  }

  String describeValue(String key, Object? value) {
    if (value == null || value == '') return '未设置';
    if (key == 'cover_fit') {
      return value == 'cover' ? '裁切填充' : '完整显示 · 保持比例';
    }
    if (key == 'cover_design' && value is Map) {
      const colors = {
        0xff23664f: '河岸绿',
        0xff82705a: '暖棕',
        0xff5e6d7d: '灰蓝',
        0xff694c52: '酒红',
      };
      return '标题：${value['title']}\n署名：${value['author']}\n'
          '系列：${value['series']}\n河岸 · 经典 / ${colors[value['color']] ?? '自定义色'}';
    }
    if (key == 'cover_crop' && value is Map) {
      String percent(String field) =>
          '${((value[field] as num) * 100).toStringAsFixed(1)}%';
      return '左 ${percent('x')} · 上 ${percent('y')}\n'
          '宽 ${percent('width')} · 高 ${percent('height')}';
    }
    return '$value';
  }

  Future<void> save() => _saving ??= _save().whenComplete(() => _saving = null);

  Future<void> _save() async {
    if (session == null || !dirty) return;
    final snapshot = Map<String, Object?>.from(values);
    final fields = Set<String>.from(touchedFields);
    try {
      final plan = await session!.preview({
        for (final entry in snapshot.entries)
          if (fields.contains(entry.key) ||
              !deskDeepEquals(entry.value, baseline[entry.key]))
            entry.key: entry.value,
      });
      await session!.apply(plan);
      if (!mounted) return;
      setState(() {
        baseline = snapshot;
        for (final key in fields) {
          if (values[key] == snapshot[key]) touchedFields.remove(key);
        }
        message = '已应用到本书';
      });
      if (!dirty) {
        autosave?.writeDraft(draftKey, null);
      } else {
        changed();
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message = '${deskErrorText(error, '暂未应用到书稿')}；输入已暂存，补全后自动应用。',
        );
      }
    }
  }

  // ---------------------------------------------------------------- 视图（设计）

  /// 窄窗时“书籍信息 / 封面”分段切换。
  int pane = 0;

  Widget field(String key, {int lines = 1}) => Column(
    key: fieldKeys[key] ??= GlobalKey(),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          DeskLabel(bookInformationFields[key]!),
          if (focusField == key) ...[
            const SizedBox(width: 8),
            Text(
              fieldProblems[key] ?? '',
              key: ValueKey('information-problem-$key'),
              style: ui(11.5, c: context.desk.warn),
            ),
          ],
        ],
      ),
      TextField(
        key: ValueKey('information-$key'),
        focusNode: fieldFocus[key] ??= FocusNode()
          ..addListener(() {
            if (fieldFocus[key]?.hasFocus == true) board?.noteField(key);
          }),
        controller: controllers[key],
        onChanged: (_) {
          setState(() {
            touchedFields.add(key);
            if (focusField == key) focusField = null;
          });
          changed();
        },
        minLines: lines,
        maxLines: lines,
        enabled: !busy,
        style: ui(13, c: context.desk.ink),
        // 语言留空时成品用设置里的默认语言，写明并给入口。
        decoration: key == 'language'
            ? marked(key, deskInput(context)).copyWith(
                hintText: '留空时用设置里的默认语言',
                suffixIcon: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: TextButton(
                    key: const ValueKey('information-language-settings'),
                    onPressed: () => GoRouter.maybeOf(context)?.go('/settings'),
                    child: const Text('去设置'),
                  ),
                ),
                suffixIconConstraints: const BoxConstraints(),
              )
            : marked(key, deskInput(context)),
      ),
    ],
  );

  /// 检查指到的输入框描上边。
  InputDecoration marked(String key, InputDecoration decoration) {
    if (focusField != key) return decoration;
    final side = BorderSide(color: context.desk.warn, width: 1.5);
    final shape = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: side,
    );
    return decoration.copyWith(enabledBorder: shape, focusedBorder: shape);
  }

  Widget pair(String first, String second) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: LayoutBuilder(
      builder: (context, c) => c.maxWidth < 420
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field(first),
                const SizedBox(height: 12),
                field(second),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: field(first)),
                const SizedBox(width: 12),
                Expanded(child: field(second)),
              ],
            ),
    ),
  );

  Widget group(String title, String note, List<Widget> rows) {
    final d = context.desk;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(title, style: ui(13.5, w: 650, c: d.ink)),
              Text(note, style: ui(11.5, c: d.ink3)),
            ],
          ),
          const SizedBox(height: 12),
          ...rows,
        ],
      ),
    );
  }

  Widget statusTag() {
    if (message.isEmpty) return const SizedBox.shrink();
    final tone = message == '已应用到本书'
        ? Tone.ok
        : message == '已恢复上次编辑的内容'
        ? Tone.neutral
        : Tone.warn;
    return Tooltip(message: message, child: DeskTag(message, tone));
  }

  Widget form() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
    children: [
      group('基本信息', '书名、作者与语言写入成品，右侧同步预览本书封面。', [
        pair('title', 'author'),
        pair('language', 'publisher'),
        pair('translator', 'isbn'),
        pair('publication_date', 'category'),
        field('description', lines: 4),
      ]),
      group('系列与分类', '可选字段；与封面一起保存到当前书。', [
        pair('series', 'series_index'),
        field('subjects'),
        pair('title_sort', 'author_sort'),
        field('book_producer'),
      ]),
      if (widget.library case final SupplementalPageLibrary library)
        SupplementalPagesCard(library: library, bookId: widget.bookId),
      Text('更改自动保存到当前书，原始文件保持不变。', style: ui(11.5, c: context.desk.ink3)),
    ],
  );

  Widget coverPanel() {
    final d = context.desk;
    return Listener(
      onPointerDown: (_) => board?.noteField('cover'),
      child: coverList(d),
    );
  }

  Widget coverList(Desk d) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          key: fieldKeys['cover'] ??= GlobalKey(),
          children: [
            Text('封面', style: ui(13.5, w: 650, c: d.ink)),
            if (focusField == 'cover' && cover == null) ...[
              const SizedBox(width: 8),
              Text(
                fieldProblems['cover']!,
                key: const ValueKey('information-problem-cover'),
                style: ui(11.5, c: d.warn),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Center(
          child: Container(
            width: 188,
            height: 251,
            decoration: BoxDecoration(
              color: d.sunken,
              borderRadius: BorderRadius.circular(4),
              boxShadow: cover == null ? null : d.shadow2,
              border: cover == null ? Border.all(color: d.line) : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: cover == null
                ? Center(
                    child: Text('尚未设置封面', style: ui(12, c: d.ink3)),
                  )
                : CoverPreview(
                    path: cover!,
                    decodeWidth: 564,
                    crop: crop == null
                        ? null
                        : Map<String, dynamic>.from(crop as Map),
                    fit: fit == 'contain'
                        ? BoxFit.contain
                        : fit == 'fill'
                        ? BoxFit.fill
                        : BoxFit.cover,
                  ),
          ),
        ),
        const SizedBox(height: 14),
        const DeskLabel('封面适配'),
        // 窄面板或大字号时整体缩小，不溢出。
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: KeyedSubtree(
            key: ValueKey(('information-fit', fit)),
            child: DeskSegmented<String>(
              value: fit,
              options: const {
                'contain': '完整显示',
                'cover': '填满封面',
                'fill': '拉伸填满',
              },
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      fit = value;
                      crop = null;
                      changed();
                    }),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('均保持原图不变；更改适配会清除现有裁切。', style: ui(11.5, c: d.ink3)),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DeskButton(
              '浏览图片…',
              icon: Icons.image_outlined,
              onPressed: busy ? null : chooseImage,
            ),
            DeskButton(
              '生成文字封面',
              icon: Icons.text_fields_rounded,
              onPressed: busy ? null : () => openCoverEditor(textCover: true),
            ),
            DeskButton(
              '裁切与调整',
              icon: Icons.crop_rounded,
              disabledReason: '先设置封面',
              onPressed: busy || cover == null
                  ? null
                  : () => openCoverEditor(textCover: false),
            ),
            DeskButton(
              '移除封面',
              quiet: true,
              icon: Icons.hide_image_outlined,
              disabledReason: '尚未设置封面',
              onPressed: busy || cover == null
                  ? null
                  : () => setState(() {
                      cover = null;
                      design = null;
                      crop = null;
                      changed();
                    }),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Divider(height: 1, color: d.line),
        const SizedBox(height: 12),
        const DeskLabel('封面标题与署名'),
        ListenableBuilder(
          listenable: Listenable.merge([
            controllers['title']!,
            controllers['author']!,
          ]),
          builder: (_, _) => Text(
            [
              controllers['title']!.text,
              controllers['author']!.text,
            ].where((v) => v.trim().isNotEmpty).join(' · '),
            style: ui(13, c: d.ink2),
          ),
        ),
        const SizedBox(height: 4),
        Text('图片中的文字保持原样。', style: ui(11.5, c: d.ink3)),
        const SizedBox(height: 14),
        Text(
          '书籍信息与封面自动保存；普通字段停顿后自动应用到本书，未填完或不合法的输入只暂存，离开或重开后恢复。',
          style: ui(11.5, c: d.ink3, h: 1.5),
        ),
      ],
    );
  }

  Future<void> discardInput() async {
    try {
      _saveTimer?.cancel();
      await _saving;
      if (!mounted) return;
      setState(() {
        _saveTimer?.cancel();
        load();
        autosave?.writeDraft(draftKey, null);
        message = '';
      });
    } catch (_) {
      setState(() => message = '书稿已不可用，请返回书库。');
    }
  }

  @override
  Widget build(BuildContext context) => DropTarget(
    onDragEntered: (_) => setState(() => dropHover = true),
    onDragExited: (_) => setState(() => dropHover = false),
    onDragDone: dropImage,
    child: Stack(
      fit: StackFit.expand,
      children: [
        _page(context),
        if (dropHover && session != null && !generating && !adjusting)
          IgnorePointer(
            child: Container(
              key: const ValueKey('information-cover-drop'),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.desk.accentSoft.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.desk.accent, width: 2),
              ),
              child: Text(
                '松开即可把图片设为封面（先预览，确认后才保存）',
                style: ui(14, w: 600, c: context.desk.accent),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _page(BuildContext context) {
    final d = context.desk;
    if (session == null) {
      return Center(
        child: Text(message, style: ui(13, c: d.ink2)),
      );
    }
    if (generating || adjusting) {
      return CoverEditorPage(
        session: session!,
        autosave: autosave,
        draftKey: 'cover:${widget.bookId}',
        title: controllers['title']!.text,
        author: controllers['author']!.text,
        series: controllers['series']!.text,
        path: cover,
        fit: fit,
        crop: crop == null ? null : Map<String, dynamic>.from(crop as Map),
        design: design,
        startWithText: generating,
        pickImage: widget.pickImage,
        onReturn: (value) => setState(() {
          generating = false;
          adjusting = false;
          widget.onEditorChanged?.call(false);
          if (value != null) {
            cover = value.path;
            design = value.design;
            crop = value.crop;
            fit = value.fit;
            changed();
          }
        }),
      );
    }
    return Material(
      color: d.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: d.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: Row(
              children: [
                const DeskPageTitle('书籍信息'),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: statusTag(),
                  ),
                ),
                DeskButton(
                  '撤销未应用输入',
                  quiet: true,
                  icon: Icons.undo_rounded,
                  onPressed: busy ? null : discardInput,
                ),
                const SizedBox(width: 6),
                DeskButton(
                  '立即保存',
                  icon: Icons.save_outlined,
                  primary: true,
                  onPressed: busy ? null : save,
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                if (c.maxWidth >= 860) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: form()),
                      Container(
                        width: 340,
                        decoration: BoxDecoration(
                          color: d.surface,
                          border: Border(left: BorderSide(color: d.line)),
                        ),
                        child: coverPanel(),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DeskSegmented<int>(
                          value: pane,
                          options: const {0: '书籍信息', 1: '封面'},
                          onChanged: (v) => setState(() => pane = v),
                        ),
                      ),
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: pane,
                        children: [form(), coverPanel()],
                      ),
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
}
