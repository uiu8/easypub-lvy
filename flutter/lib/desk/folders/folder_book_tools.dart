// 文件夹书稿列表的排序、类型筛选与勾选工具条（V84，FOLD-083–086）：
// 文件夹页与“导入文件夹”弹窗共用。排序与筛选只改显示顺序，不改勾选；
// “全选 / 取消全选 / 反选”只作用于当前筛选下可勾选的书（书库已有的跳过）。
import 'package:flutter/material.dart';

import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';
import '../widgets.dart';

enum FolderSort { name, type, size, modified }

const folderSortLabels = <FolderSort, String>{
  FolderSort.name: '名称',
  FolderSort.type: '类型',
  FolderSort.size: '大小',
  FolderSort.modified: '修改时间',
};

/// 列表的显示方式（排序、方向、类型），由页面持有。
class FolderListView {
  FolderSort sort = FolderSort.name;
  bool descending = false;
  String type = '';

  /// 点列名：同一列再点切换方向；换列时名称、类型升序，大小、时间降序（大的、新的在前）。
  void sortBy(FolderSort value) {
    if (sort == value) {
      descending = !descending;
    } else {
      sort = value;
      descending = value == FolderSort.size || value == FolderSort.modified;
    }
  }

  List<FolderBook> apply(List<FolderBook> books) {
    final shown = [
      for (final b in books)
        if (type.isEmpty || b.type == type) b,
    ];
    int byName(FolderBook a, FolderBook b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    int compare(FolderBook a, FolderBook b) {
      final primary = switch (sort) {
        FolderSort.name => byName(a, b),
        FolderSort.type => a.type.compareTo(b.type),
        FolderSort.size => a.bytes.compareTo(b.bytes),
        FolderSort.modified => (a.modified ?? DateTime(0)).compareTo(
          b.modified ?? DateTime(0),
        ),
      };
      return primary != 0 ? primary : byName(a, b);
    }

    shown.sort((a, b) => descending ? compare(b, a) : compare(a, b));
    return shown;
  }
}

String folderBookTime(DateTime? when) {
  if (when == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${when.year}-${two(when.month)}-${two(when.day)} '
      '${two(when.hour)}:${two(when.minute)}';
}

String folderBookSize(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : bytes >= 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '$bytes B';

/// 勾选与显示工具条：已选计数、全选 / 取消全选 / 反选、类型筛选、排序。
class FolderListToolbar extends StatelessWidget {
  const FolderListToolbar({
    super.key,
    required this.books,
    required this.shown,
    required this.selected,
    required this.view,
    required this.onViewChanged,
    required this.onSet,
    this.enabled = true,
  });

  /// 扫描到的全部书与当前筛选下显示的书。
  final List<FolderBook> books, shown;
  final Set<String> selected;
  final FolderListView view;
  final VoidCallback onViewChanged;

  /// 一次勾选或取消多本（书库已有的由调用方跳过）。
  final void Function(Iterable<String> paths, bool value) onSet;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final selectable = [
      for (final b in shown)
        if (!b.alreadyImported) b.path,
    ];
    final checked = selectable.where(selected.contains).length;
    final types = {for (final b in books) b.type}.where((t) => t.isNotEmpty);
    final on = enabled && selectable.isNotEmpty;
    return Wrap(
      spacing: 4,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(
            '已选 ${selected.length} 本 · 可选 ${selectable.length} 本',
            key: const ValueKey('folder-selected-count'),
            style: ui(12.5, w: 600, c: d.ink),
          ),
        ),
        DeskButton(
          '全选',
          key: const ValueKey('folder-select-all'),
          icon: Icons.select_all_rounded,
          tooltip: '勾选当前列表里所有可导入的书（Ctrl+A）',
          onPressed: on && checked < selectable.length
              ? () => onSet(selectable, true)
              : null,
        ),
        DeskButton(
          '取消全选',
          key: const ValueKey('folder-select-none'),
          icon: Icons.deselect_rounded,
          tooltip: '取消当前列表里的全部勾选（Esc）',
          onPressed: on && checked > 0 ? () => onSet(selectable, false) : null,
        ),
        DeskButton(
          '反选',
          key: const ValueKey('folder-select-invert'),
          icon: Icons.flip_rounded,
          quiet: true,
          tooltip: '已勾选的取消，未勾选的勾上',
          onPressed: on
              ? () {
                  final was = selectable.where(selected.contains).toList();
                  onSet(
                    selectable.where((p) => !selected.contains(p)).toList(),
                    true,
                  );
                  onSet(was, false);
                }
              : null,
        ),
        const SizedBox(width: 10),
        if (types.length > 1)
          DeskSegmented<String>(
            key: const ValueKey('folder-type-filter'),
            value: view.type,
            options: {'': '全部类型', for (final t in types) t: t},
            onChanged: (v) {
              view.type = v;
              onViewChanged();
            },
          ),
        Tooltip(
          message: '排序方式',
          child: DeskFilter<FolderSort>(
            key: const ValueKey('folder-sort'),
            value: view.sort,
            label: '排序',
            onChanged: (v) {
              if (v == null) return;
              view.sortBy(v);
              onViewChanged();
            },
            items: [
              for (final e in folderSortLabels.entries)
                DropdownMenuItem(value: e.key, child: Text('按${e.value}')),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('folder-sort-direction'),
          tooltip: view.descending ? '降序（点击改为升序）' : '升序（点击改为降序）',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            view.descending
                ? Icons.arrow_downward_rounded
                : Icons.arrow_upward_rounded,
            size: 18,
            color: d.ink2,
          ),
          onPressed: () {
            view.descending = !view.descending;
            onViewChanged();
          },
        ),
      ],
    );
  }
}

/// 可点击排序的列名：当前排序列显示方向箭头。
class FolderSortHeader extends StatelessWidget {
  const FolderSortHeader(
    this.label,
    this.sort, {
    super.key,
    required this.view,
    required this.onViewChanged,
  });
  final String label;
  final FolderSort sort;
  final FolderListView view;
  final VoidCallback onViewChanged;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final active = view.sort == sort;
    return InkWell(
      key: ValueKey('folder-sort-${sort.name}'),
      borderRadius: BorderRadius.circular(4),
      onTap: () {
        view.sortBy(sort);
        onViewChanged();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: ui(
                  11.5,
                  w: active ? 700 : 600,
                  c: active ? d.ink : d.ink3,
                ),
              ),
            ),
            if (active)
              Icon(
                view.descending
                    ? Icons.arrow_drop_down_rounded
                    : Icons.arrow_drop_up_rounded,
                size: 16,
                color: d.ink2,
              ),
          ],
        ),
      ),
    );
  }
}
