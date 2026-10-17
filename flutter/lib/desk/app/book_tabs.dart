// 书籍标签页（V69，G-073）：同时打开几本书，在标题栏下方切换。
// 每个标签记住这本书最后停留的页面（含参数），点标签回到那里；最多 8 个，超出时去掉最久没用的。
// 标签随工作区一起保存（workspace/UI 的 tabs），重开后恢复；已移出书库的书自动去掉。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../application/library_service.dart';
import '../shell/page_menu.dart' show bookToolTitles;
import '../tokens.dart';

class BookTab {
  BookTab(this.bookId, this.location);
  final String bookId;

  /// 这本书最后停留的页面地址，例如 /books/abc/checks?rule=…。
  String location;
}

class BookTabs extends ChangeNotifier {
  static const limit = 8;
  final List<BookTab> tabs = [];

  /// 当前页面所属的书；在书库、设置等非书页面时为空。
  String? active;

  /// 最近使用顺序（最近的在最后），用于超出上限时去掉最久没用的。
  final List<String> _used = [];

  int indexOf(String bookId) => tabs.indexWhere((t) => t.bookId == bookId);

  /// 路由切换时调用：书页面记下位置并设为当前，其他页面清空当前。
  void visit(Uri location) {
    final s = location.pathSegments;
    if (s.length < 3 || s.first != 'books') {
      if (active != null) {
        active = null;
        notifyListeners();
      }
      return;
    }
    final id = s[1];
    final i = indexOf(id);
    if (i >= 0) {
      tabs[i].location = location.toString();
    } else {
      if (tabs.length >= limit) {
        final victim = _used.firstWhere(
          (b) => b != id,
          orElse: () => tabs.first.bookId,
        );
        _remove(victim);
      }
      tabs.add(BookTab(id, location.toString()));
    }
    _used
      ..remove(id)
      ..add(id);
    active = id;
    notifyListeners();
  }

  void _remove(String bookId) {
    tabs.removeWhere((t) => t.bookId == bookId);
    _used.remove(bookId);
  }

  /// 关闭标签；关的是当前标签时返回应转到的地址（相邻标签，没有时回书库），否则返回 null。
  String? close(String bookId) {
    final i = indexOf(bookId);
    if (i < 0) return null;
    final wasActive = active == bookId;
    _remove(bookId);
    String? next;
    if (wasActive) {
      active = null;
      next = tabs.isEmpty ? '/' : tabs[i.clamp(0, tabs.length - 1)].location;
    }
    notifyListeners();
    return next;
  }

  /// 相邻标签的地址（[delta] 为 1 或 -1，循环）；没有标签时为 null。
  String? neighbor(int delta) {
    if (tabs.isEmpty) return null;
    final i = active == null ? -1 : indexOf(active!);
    final next = i < 0
        ? (delta > 0 ? 0 : tabs.length - 1)
        : (i + delta) % tabs.length;
    return tabs[next < 0 ? next + tabs.length : next].location;
  }

  /// 只保留书库里还在的书。
  void retain(Set<String> ids) {
    final before = tabs.length;
    for (final t in [...tabs]) {
      if (!ids.contains(t.bookId)) _remove(t.bookId);
    }
    if (active != null && !ids.contains(active)) active = null;
    if (tabs.length != before) notifyListeners();
  }

  List<Map<String, String>> toJson() => [
    for (final t in tabs) {'book': t.bookId, 'route': t.location},
  ];

  void restore(Object? raw, Set<String> ids) {
    tabs.clear();
    _used.clear();
    for (final e in (raw is List ? raw : const []).whereType<Map>()) {
      final id = e['book'], route = e['route'];
      if (id is! String || route is! String || !ids.contains(id)) continue;
      final uri = Uri.tryParse(route);
      if (uri == null ||
          uri.pathSegments.length < 3 ||
          uri.pathSegments.first != 'books' ||
          uri.pathSegments[1] != id ||
          indexOf(id) >= 0 ||
          tabs.length >= limit) {
        continue;
      }
      tabs.add(BookTab(id, route));
      _used.add(id);
    }
    notifyListeners();
  }
}

/// 标题栏下方的书籍标签条。没有标签时不占位置。
class BookTabBar extends StatelessWidget {
  const BookTabBar({
    super.key,
    required this.tabs,
    required this.library,
    required this.onOpen,
  });
  final BookTabs tabs;
  final LibraryService library;

  /// 转到某个地址（标签、相邻标签、书库）。
  final void Function(String location) onOpen;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return ListenableBuilder(
      listenable: Listenable.merge([tabs, library.books]),
      builder: (context, _) {
        if (tabs.tabs.isEmpty) return const SizedBox.shrink();
        final titles = {for (final b in library.books.value) b.id: b.title};
        return Container(
          key: const ValueKey('book-tabs'),
          height: 34,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          decoration: BoxDecoration(
            color: d.rail,
            border: Border(bottom: BorderSide(color: d.line)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final t in tabs.tabs)
                        _Tab(
                          tab: t,
                          title: titles[t.bookId] ?? '（未命名）',
                          active: t.bookId == tabs.active,
                          onOpen: () => onOpen(t.location),
                          onClose: () {
                            final next = tabs.close(t.bookId);
                            if (next != null) onOpen(next);
                          },
                        ),
                    ],
                  ),
                ),
              ),
              Tooltip(
                message: '回到书库打开另一本书',
                child: InkWell(
                  key: const ValueKey('book-tab-new'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onOpen('/'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.add_rounded, size: 16, color: d.ink2),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.title,
    required this.active,
    required this.onOpen,
    required this.onClose,
  });
  final BookTab tab;
  final String title;
  final bool active;
  final VoidCallback onOpen, onClose;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final segments = Uri.parse(tab.location).pathSegments;
    final page = segments.length > 2 ? bookToolTitles[segments[2]] : null;
    return Listener(
      // 中键关闭。
      onPointerDown: (e) {
        if (e.buttons == kMiddleMouseButton) onClose();
      },
      child: Tooltip(
        message: page == null ? title : '$title · $page',
        waitDuration: const Duration(milliseconds: 600),
        child: Material(
          key: ValueKey(('book-tab', tab.bookId)),
          color: active ? d.surface : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            side: active ? BorderSide(color: d.line) : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            onTap: active ? null : onOpen,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.menu_book_outlined,
                    size: 14,
                    color: active ? d.accent : d.ink3,
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: title,
                            style: ui(
                              12.5,
                              w: active ? 600 : 450,
                              c: active ? d.ink : d.ink2,
                            ),
                          ),
                          if (page != null)
                            TextSpan(
                              text: ' · $page',
                              style: ui(12, c: d.ink3),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Tooltip(
                    message: '关闭标签（中键也可以）',
                    child: InkWell(
                      key: ValueKey(('book-tab-close', tab.bookId)),
                      borderRadius: BorderRadius.circular(4),
                      onTap: onClose,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(
                          Icons.close_rounded,
                          size: 13,
                          color: d.ink3,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
