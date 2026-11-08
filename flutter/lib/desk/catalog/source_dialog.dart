// 获取参考目录（CH-180–202）：在线 / 书源（V45，CH-270–276）/ 本地 / 粘贴四种来源，搜索书名、获取目录、重复片段核对、
// 访问设置（窗口 Cookie 与本机凭据）。获取只生成候选，不保存、不改书稿。
// 请求、凭据与取消逻辑沿用 V3 前的 CatalogSourceDialog；设计：design_review_v37/d2_catalog.dart（D2-J）。
import 'package:flutter/material.dart';

import '../errors.dart';

import 'package:flutter/services.dart';

import '../../application/book_source_errors.dart';
import '../../application/catalog_service.dart';
import '../controls/controls.dart' show DeskButton, DeskChoice, DeskCommandMenu;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'paste_field.dart';

class CatalogSourceDialog extends StatefulWidget {
  const CatalogSourceDialog({
    super.key,
    required this.session,
    required this.pickFile,
    this.pickBookSourceFile,
  });
  final CatalogSession session;
  final Future<String?> Function() pickFile;

  /// 选择书源 JSON（V45）；为空时“导入书源”不可用。
  final Future<String?> Function()? pickBookSourceFile;
  @override
  State<CatalogSourceDialog> createState() => _CatalogSourceDialogState();
}

class _CatalogSourceDialogState extends State<CatalogSourceDialog> {
  final input = TextEditingController(), cookie = TextEditingController();
  final total = TextEditingController();
  String source = 'qidian', error = '';
  CatalogSnapshot? candidate;
  List<CatalogSearchResult> results = const [];
  bool useCache = true, accessOpen = false;
  bool get searching =>
      source == 'qidian' &&
      input.text.trim().isNotEmpty &&
      !RegExp(
        r'^(https?://|www\.|//)',
        caseSensitive: false,
      ).hasMatch(input.text.trim());
  CatalogCredentialSession? get credentials =>
      widget.session is CatalogCredentialSession
      ? widget.session as CatalogCredentialSession
      : null;
  bool credentialBusy = false, savedCredential = false;
  String credentialMessage = '';

  // ---- 书源目录（V45，CH-270–276）
  BookSourceSession? get bookSourceService =>
      widget.session is BookSourceSession
      ? widget.session as BookSourceSession
      : null;
  List<BookSourceInfo> bookSources = const [];
  bool bookSourcesLoaded = false, onlyUsable = false;
  String? bookSourceId;
  List<BookSourceSearchResult> bookResults = const [];
  BookSourceSearchResult? chosenBook;
  int get usableCount => bookSources.where((s) => s.supported).length;
  @override
  void initState() {
    super.initState();
    refreshCredential();
  }

  Future<void> refreshCredential() async {
    final service = credentials;
    if (service == null) return;
    setState(() => credentialBusy = true);
    try {
      final saved = await service.credentialSaved();
      if (mounted) setState(() => savedCredential = saved);
    } catch (_) {
      if (mounted) {
        setState(() => credentialMessage = '无法读取本机保存状态；仍可使用当前窗口Cookie。');
      }
    } finally {
      if (mounted) setState(() => credentialBusy = false);
    }
  }

  Future<void> changeCredential(bool clear) async {
    final service = credentials;
    if (service == null || busy || credentialBusy) return;
    setState(() {
      credentialBusy = true;
      credentialMessage = '';
    });
    try {
      if (clear) {
        await service.clearCredential();
      } else {
        await service.saveCredential(cookie.text);
      }
      if (!mounted) return;
      setState(() {
        savedCredential = !clear;
        credentialMessage = clear ? '已清除本机Cookie。' : '已在本机保护保存。';
      });
    } catch (e) {
      if (mounted) {
        setState(() => credentialMessage = deskErrorText(e, '操作未完成，原有凭据保持不变。'));
      }
    } finally {
      if (mounted) setState(() => credentialBusy = false);
    }
  }

  bool busy = false, returned = false;
  int generation = 0;
  @override
  void dispose() {
    generation++;
    if (!returned) widget.session.cancel();
    input.dispose();
    cookie.dispose();
    total.dispose();
    super.dispose();
  }

  void invalidate() => setState(() {
    candidate = null;
    error = '';
    results = const [];
    bookResults = const [];
    chosenBook = null;
  });

  /// 运行一次书源请求：同一时间一个，迟到结果按 generation 丢弃。
  Future<void> bookSourceTask(
    Future<void> Function(int ticket) run,
    String fallback,
  ) async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await run(ticket);
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() => error = deskErrorText(e, fallback));
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  void adoptSources(List<BookSourceInfo> list) {
    bookSources = list;
    bookSourcesLoaded = true;
    if (!list.any((s) => s.id == bookSourceId && s.supported)) {
      bookSourceId = list.where((s) => s.supported).firstOrNull?.id;
    }
  }

  Future<void> loadBookSources() async {
    final service = bookSourceService;
    if (service == null || bookSourcesLoaded) return;
    await bookSourceTask((ticket) async {
      final list = await service.listBookSources();
      if (mounted && ticket == generation) setState(() => adoptSources(list));
    }, '无法读取本机书源，请重新导入。');
  }

  Future<void> importBookSources() async {
    final service = bookSourceService, pick = widget.pickBookSourceFile;
    if (service == null || pick == null || busy) return;
    final String? path;
    try {
      path = await pick();
    } catch (_) {
      if (mounted) setState(() => error = '无法打开文件选择器，请重试。');
      return;
    }
    if (!mounted || path == null) return;
    await bookSourceTask((ticket) async {
      final list = await service.importBookSources(path!);
      if (mounted && ticket == generation) {
        setState(() {
          adoptSources(list);
          bookResults = const [];
          chosenBook = null;
          candidate = null;
        });
      }
    }, '书源导入失败，原有书源保持不变。');
  }

  Future<void> clearBookSources() async {
    final service = bookSourceService;
    if (service == null || busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => DeskAlert(
        title: const Text('清空本机书源？'),
        content: const Text('删除本机保存的全部书源和书源目录缓存。书稿里已经采用的参考目录不受影响。'),
        actions: [
          DeskButton(
            '取消',
            quiet: true,
            onPressed: () => Navigator.pop(context, false),
          ),
          DeskButton(
            '清空',
            key: const ValueKey('book-source-clear-confirm'),
            primary: true,
            dangerous: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await bookSourceTask((ticket) async {
      await service.clearBookSources();
      if (mounted && ticket == generation) {
        setState(() {
          adoptSources(const []);
          bookResults = const [];
          chosenBook = null;
          candidate = null;
          input.clear();
        });
      }
    }, '清空未完成，本机书源保持不变。');
  }

  Future<void> searchBookSource() async {
    final service = bookSourceService, id = bookSourceId;
    if (service == null || id == null || input.text.trim().isEmpty) return;
    await bookSourceTask((ticket) async {
      setState(() {
        bookResults = const [];
        chosenBook = null;
        candidate = null;
      });
      final found = await service.searchBookSource(id, input.text.trim());
      if (mounted && ticket == generation) {
        setState(() {
          bookResults = found;
          if (found.isEmpty) error = '这个书源没有搜到结果，请换个书名或换一个书源。';
        });
      }
    }, '书源搜索失败，请换一个书源或稍后再试。');
  }

  Future<void> chooseBookResult(BookSourceSearchResult book) async {
    final service = bookSourceService;
    if (service == null || busy) return;
    setState(() {
      chosenBook = book;
      candidate = null;
    });
    await bookSourceTask((ticket) async {
      final result = await service.acquireBookSource(book, useCache: useCache);
      if (mounted && ticket == generation) setState(() => candidate = result);
    }, '目录抓取失败，请换一个结果或书源。');
  }

  Future<void> pasteCredential() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || busy || data?.text == null) return;
      if (data!.text!.length > 512 * 1024) {
        setState(() => error = 'Cookie导出内容过大，请仅导出起点所需凭据。');
        return;
      }
      cookie.text = data.text!;
      invalidate();
    } catch (_) {
      if (mounted) setState(() => error = '无法读取剪贴板，请重新复制Cookie。');
    }
  }

  Future<void> acquire() async {
    if (credentialBusy) return;
    final ticket = ++generation;
    final credential = cookie.text;
    setState(() {
      busy = true;
      candidate = null;
      results = const [];
      error = '';
    });
    try {
      if (searching) {
        final found = await widget.session.search(
          input.text,
          cookie: credential,
        );
        if (mounted && ticket == generation) {
          setState(() {
            results = found;
            if (found.isEmpty) error = '未找到结果，请换用更完整的书名或粘贴书籍链接。';
          });
        }
        return;
      }
      final count = source == 'qidian' || total.text.trim().isEmpty
          ? null
          : int.tryParse(total.text.trim());
      if (source != 'qidian' && total.text.trim().isNotEmpty && count == null) {
        throw const FormatException('请输入整数章节数，或留空保留完整性待核对。');
      }
      final result = await widget.session.acquire(
        source,
        input.text,
        cookie: credential,
        declaredTotal: count,
        useCache: useCache,
      );
      if (mounted && ticket == generation) setState(() => candidate = result);
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() => error = deskErrorText(e, '目录读取失败，请检查来源。'));
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> reviewDuplicates() async {
    final current = candidate;
    if (current == null || busy) return;
    final chosen = current.duplicateSegments.map((d) => d.start).toSet();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => DeskDialog(
          title: '核对重复目录片段',
          subtitle: '以下目录片段与前一段完全重复。仅移除勾选的参考条目，不删除原书正文；若是确有重复的章节，请取消并核对目录范围。',
          closeTooltip: '取消',
          width: 600,
          onClose: () => Navigator.pop(context, false),
          actions: [
            DeskButton(
              '取消',
              quiet: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            DeskButton(
              '移除勾选片段',
              primary: true,
              disabledReason: '至少勾选一段',
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final d in current.duplicateSegments)
                DeskChoiceRow(
                  radio: false,
                  selected: chosen.contains(d.start),
                  title:
                      '第${d.start + 1}–${d.start + d.length}项，与第${d.originalStart + 1}项起的${d.length}项相同',
                  detail: '${d.firstTitle} → ${d.lastTitle}',
                  onTap: () => update(() {
                    chosen.contains(d.start)
                        ? chosen.remove(d.start)
                        : chosen.add(d.start);
                  }),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || confirmed != true || !identical(current, candidate)) return;
    final ticket = ++generation;
    setState(() => busy = true);
    try {
      final result = await widget.session.removeDuplicateSegments(
        current,
        chosen,
      );
      if (mounted && ticket == generation) {
        setState(() {
          candidate = result;
          error = '';
        });
      }
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() => error = deskErrorText(e, '重复片段处理失败，请重新获取。'));
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> browse() async {
    setState(() => busy = true);
    try {
      final path = await widget.pickFile();
      if (mounted && path != null) {
        input.text = path;
        invalidate();
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法打开文件选择器，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------------------------------------------------------------- 视图

  Widget fieldWithLabel(
    TextEditingController c,
    String label, {
    String? helper,
    bool secret = false,
    TextInputType? type,
  }) {
    final d = context.desk;
    return TextField(
      controller: c,
      enabled: !busy,
      obscureText: secret,
      keyboardType: type,
      style: ui(13, c: d.ink),
      onChanged: secret ? null : (_) => invalidate(),
      minLines: 1,
      maxLines: secret ? 1 : 2,
      decoration: deskInput(context).copyWith(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        helperStyle: ui(11.5, c: d.ink3),
      ),
    );
  }

  Widget identityRow(String title, String text, {Widget? tail}) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(title, style: ui(12, c: d.ink3)),
          ),
          Expanded(
            child: Text(text, style: ui(12.5, c: d.ink)),
          ),
          ?tail,
        ],
      ),
    );
  }

  /// 书源页签主体（V45，CH-270–276）。
  List<Widget> bookSourcePanel() {
    final d = context.desk;
    if (!bookSourcesLoaded && busy) {
      return const [SizedBox(height: 60)];
    }
    if (bookSources.isEmpty) {
      return [
        Padding(
          key: const ValueKey('book-source-empty'),
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Column(
            children: [
              Icon(
                Icons.collections_bookmark_outlined,
                size: 28,
                color: d.ink3,
              ),
              const SizedBox(height: 8),
              Text('导入“阅读”App 的书源文件', style: ui(13.5, w: 600, c: d.ink)),
              const SizedBox(height: 4),
              Text(
                '选择书源 JSON 后，可按书名搜索并抓取目录。\n需要 JavaScript、登录的书源会标出原因，暂不能用。',
                textAlign: TextAlign.center,
                style: ui(12, c: d.ink3, h: 1.6),
              ),
              const SizedBox(height: 12),
              DeskButton(
                '导入书源…',
                key: const ValueKey('book-source-import'),
                primary: true,
                icon: Icons.file_open_outlined,
                disabledReason: '当前窗口不能选择文件',
                onPressed: busy || widget.pickBookSourceFile == null
                    ? null
                    : importBookSources,
              ),
            ],
          ),
        ),
      ];
    }
    final shown = onlyUsable
        ? bookSources.where((s) => s.supported).toList()
        : bookSources;
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DeskChoice<String>(
              key: const ValueKey('book-source-choice'),
              value: bookSourceId,
              decoration: deskInput(context).copyWith(labelText: '书源'),
              hint: const Text('选择可用书源'),
              searchable: true,
              searchText: (id) {
                final s = bookSources.firstWhere((s) => s.id == id);
                return '${s.name} ${s.group} ${s.url}';
              },
              selectedLabel: (id) => Text(
                bookSources.firstWhere((s) => s.id == id).name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              items: [
                for (final s in shown)
                  DropdownMenuItem(
                    value: s.id,
                    enabled: s.supported,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(13, c: s.supported ? d.ink : d.ink3),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          s.supported
                              ? (Uri.tryParse(s.url)?.host ?? '')
                              : bookSourceShortReasons[s.reasonCode] ??
                                    s.reason,
                          style: ui(11.5, c: d.ink3),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (id) {
                      if (id == null || id == bookSourceId) return;
                      generation++;
                      widget.session.cancel();
                      setState(() {
                        bookSourceId = id;
                        bookResults = const [];
                        chosenBook = null;
                        candidate = null;
                        error = '';
                      });
                    },
            ),
          ),
          const SizedBox(width: 8),
          DeskButton(
            '导入书源…',
            key: const ValueKey('book-source-import'),
            icon: Icons.file_open_outlined,
            disabledReason: '当前窗口不能选择文件',
            onPressed: busy || widget.pickBookSourceFile == null
                ? null
                : importBookSources,
          ),
          DeskCommandMenu<String>(
            key: const ValueKey('book-source-more'),
            tooltip: '更多书源操作',
            enabled: !busy,
            onSelected: (action) => action == 'usable'
                ? setState(() => onlyUsable = !onlyUsable)
                : clearBookSources(),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'usable',
                checked: onlyUsable,
                child: const Text('只显示可用书源'),
              ),
              const PopupMenuItem(value: 'clear', child: Text('清空本机书源…')),
            ],
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        '可用 $usableCount / 共 ${bookSources.length} 个书源 · “可用”只表示规则能执行，不代表网站一定能访问',
        key: const ValueKey('book-source-count'),
        style: ui(11.5, c: d.ink3),
      ),
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: fieldWithLabel(input, '书名')),
          const SizedBox(width: 8),
          DeskButton(
            '搜索',
            key: const ValueKey('book-source-search'),
            primary: true,
            icon: Icons.search_rounded,
            disabledReason: bookSourceId == null ? '先选择可用书源' : '先输入书名',
            onPressed: busy || bookSourceId == null || input.text.trim().isEmpty
                ? null
                : searchBookSource,
          ),
        ],
      ),
      SizedBox(
        height: 2,
        child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
      ),
      const SizedBox(height: 6),
      if (bookResults.isNotEmpty)
        Container(
          key: const ValueKey('book-source-results'),
          constraints: const BoxConstraints(maxHeight: 220),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            border: Border.all(color: d.line),
            borderRadius: BorderRadius.circular(9),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: bookResults.length,
              itemBuilder: (context, index) {
                final book = bookResults[index];
                final on = identical(book, chosenBook);
                return DeskChoiceRow(
                  selected: on,
                  title: book.author.isEmpty
                      ? book.title
                      : '${book.title} · ${book.author}',
                  detail: book.lastChapter.isEmpty
                      ? null
                      : '最新：${book.lastChapter}',
                  onTap: busy ? null : () => chooseBookResult(book),
                );
              },
            ),
          ),
        ),
      if (busy && chosenBook != null) ...[
        Text(
          '正在抓取《${chosenBook!.title}》的目录；长篇可能要翻几十页，需要几十秒，可点“取消”中止。',
          key: const ValueKey('book-source-fetching'),
          style: ui(12, c: d.ink2),
        ),
        const SizedBox(height: 8),
      ],
      DeskNote(
        '书源来自第三方分享，目录只作参考，抓取后请核对书名、作者和章节数。不会向书源网站发送起点 Cookie。',
        tone: Tone.neutral,
      ),
      const SizedBox(height: 8),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: '获取参考目录',
      subtitle: '获取后核对书名、作者和章节数量',
      closeTooltip: '关闭目录来源',
      width: 720,
      footerLeft: Text(
        '窗口输入关闭后清除；只有点击保存才保留到本机，不写入书稿项目。',
        style: ui(11.5, c: d.ink3),
      ),
      actions: [
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          '预览目录',
          primary: true,
          icon: Icons.arrow_forward_rounded,
          disabledReason: '先获取目录',
          onPressed: busy || candidate == null
              ? null
              : () {
                  returned = true;
                  Navigator.pop(context, candidate);
                },
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: KeyedSubtree(
              key: const ValueKey('catalog-source'),
              child: DeskSegmented<String>(
                value: source,
                options: {
                  'qidian': '在线目录',
                  if (bookSourceService != null) 'book_source': '书源目录',
                  'local': '本地目录',
                  'paste': '粘贴目录',
                },
                onChanged: busy
                    ? null
                    : (key) {
                        generation++;
                        widget.session.cancel();
                        input.clear();
                        cookie.clear();
                        setState(() {
                          source = key;
                          results = const [];
                          bookResults = const [];
                          chosenBook = null;
                          candidate = null;
                          error = '';
                        });
                        if (key == 'book_source') loadBookSources();
                      },
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (source == 'book_source')
            ...bookSourcePanel()
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: source == 'paste'
                      ? CatalogPasteField(
                          controller: input,
                          enabled: !busy,
                          onChanged: invalidate,
                        )
                      : fieldWithLabel(
                          input,
                          source == 'qidian' ? '书名或起点书籍链接' : '本地目录文件',
                        ),
                ),
                const SizedBox(width: 8),
                DeskButton(
                  searching ? '搜索书名' : '获取目录',
                  primary: true,
                  icon: searching
                      ? Icons.search_rounded
                      : Icons.download_rounded,
                  onPressed: busy || credentialBusy || input.text.trim().isEmpty
                      ? null
                      : acquire,
                ),
              ],
            ),
          if (source == 'local') ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: DeskButton(
                '选择目录文件…',
                icon: Icons.folder_open_rounded,
                onPressed: busy ? null : browse,
              ),
            ),
          ],
          SizedBox(
            height: 2,
            child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          const SizedBox(height: 8),
          if (source == 'qidian' ||
              source == 'book_source' && bookSources.isNotEmpty) ...[
            if (source == 'qidian' && results.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: d.line),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final result = results[index];
                      return InkWell(
                        onTap: busy
                            ? null
                            : () {
                                input.text = result.url;
                                setState(() => results = const []);
                                acquire();
                              },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      result.title,
                                      style: ui(13, w: 600, c: d.ink),
                                    ),
                                    Text(
                                      '书籍编号 ${result.id}',
                                      style: ui(11.5, c: d.ink3),
                                    ),
                                  ],
                                ),
                              ),
                              Text('获取此目录', style: ui(12, c: d.ink2)),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                                color: d.ink3,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            DeskChoiceRow(
              radio: false,
              selected: useCache,
              title: '优先使用缓存',
              detail: candidate?.fromCache == true
                  ? (candidate!.cacheStale ? '来自过期缓存，请取消勾选缓存后刷新核对。' : '来自本地缓存。')
                  : '取消勾选后重新获取网站目录',
              onTap: busy ? null : () => setState(() => useCache = !useCache),
            ),
          ],
          if (source == 'local' || source == 'paste') ...[
            const SizedBox(height: 4),
            fieldWithLabel(
              total,
              '声明的章节总数（可选）',
              helper: '仅在已核实目录范围时填写；留空不会自动认定完整。',
              type: TextInputType.number,
            ),
          ],
          if (source != 'book_source' || bookSources.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: d.sunken,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  identityRow(
                    '书籍身份',
                    candidate == null
                        ? '获取后核对书名、作者和章节数量'
                        : '${candidate!.title} · ${candidate!.author.isEmpty ? '作者未提供' : candidate!.author} · ${candidate!.entries.length} 条目录',
                  ),
                  identityRow(
                    '卷章分组',
                    source == 'book_source'
                        ? '按书源目录的卷名分组；书源来自第三方分享，请核对后再用'
                        : '保留真实分组名，区分 VIP / 免费等访问分组',
                  ),
                  if (candidate?.duplicateSegments.isNotEmpty == true) ...[
                    const SizedBox(height: 4),
                    DeskNote(
                      '先集中核对重复片段，避免生成大量重复待核对项。原书正文不变。',
                      title: '发现 ${candidate!.duplicateSegments.length} 段重复目录',
                      tone: Tone.warn,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DeskButton(
                        '核对重复片段',
                        onPressed: busy ? null : reviewDuplicates,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (source == 'qidian') ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => accessOpen = !accessOpen),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      accessOpen
                          ? Icons.expand_more_rounded
                          : Icons.chevron_right_rounded,
                      size: 18,
                      color: d.ink2,
                    ),
                    const SizedBox(width: 4),
                    Text('访问设置', style: ui(12.5, w: 600, c: d.ink)),
                  ],
                ),
              ),
            ),
            if (accessOpen)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: d.sunken,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: fieldWithLabel(
                            cookie,
                            '当前窗口 Cookie（可选）',
                            helper: '导出格式请用右侧粘贴按钮保留换行。',
                            secret: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        DeskButton(
                          '粘贴Cookie',
                          icon: Icons.content_paste_rounded,
                          onPressed: busy ? null : pasteCredential,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '支持Cookie请求头、Netscape、浏览器JSON导出，以及“名字=制表符值”（值可折行）。',
                      style: ui(11.5, c: d.ink3),
                    ),
                    if (credentials != null) ...[
                      const SizedBox(height: 8),
                      DeskChoiceRow(
                        radio: false,
                        selected: credentials!.useSavedCredential,
                        title: '输入留空时使用本机保存的Cookie',
                        onTap: busy || credentialBusy
                            ? null
                            : () => setState(
                                () => credentials!.useSavedCredential =
                                    !credentials!.useSavedCredential,
                              ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DeskButton(
                            savedCredential ? '替换本机Cookie' : '保存到本机',
                            onPressed: busy || credentialBusy
                                ? null
                                : () => changeCredential(false),
                          ),
                          DeskButton(
                            '清除已保存Cookie',
                            quiet: true,
                            onPressed: busy || credentialBusy
                                ? null
                                : () => changeCredential(true),
                          ),
                          Text(
                            credentialMessage.isNotEmpty
                                ? credentialMessage
                                : savedCredential
                                ? '本机已保存 · 仅用于起点目录'
                                : '本机尚未保存Cookie',
                            style: ui(11.5, c: d.ink2),
                          ),
                        ],
                      ),
                      if (credentialBusy)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                    ],
                  ],
                ),
              ),
          ],
          if (error.isNotEmpty) ...[
            const SizedBox(height: 12),
            DeskNote(error, title: '目录读取未完成', tone: Tone.pen),
          ],
        ],
      ),
    );
  }
}
