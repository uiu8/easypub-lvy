// 加入收藏夹与套用预设信息（V84，LIB-120–124）：书库多选、拖入、导入后加入共用这一条链：
// 加入分组 → 有预设信息时预览（或按收藏夹设置直接应用）→ 提示里可整批撤销。
import 'package:flutter/material.dart';

import '../../application/book_collection_service.dart';
import '../errors.dart';
import 'collection_dialogs.dart';

/// 把书加入收藏夹；新加入的书按收藏夹的预设信息处理。返回新加入的数量。
Future<int> joinCollection(
  BuildContext context,
  BookCollectionService service,
  String collectionId,
  Iterable<String> bookIds,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final List<String> added;
  try {
    added = service.addToCollection(collectionId, bookIds);
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text(deskErrorText(e, '未能加入收藏夹。'))),
    );
    return 0;
  }
  final collection = service.collections.value
      .where((c) => c.id == collectionId)
      .firstOrNull;
  if (collection == null) return added.length;
  final total = bookIds.toSet().length;
  if (!collection.hasTemplate || added.isEmpty) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          added.isEmpty
              ? '这些书都已在“${collection.name}”里。'
              : '已把 ${added.length} 本加入“${collection.name}”'
                    '${total > added.length ? '，${total - added.length} 本原本就在' : ''}。',
        ),
      ),
    );
    return added.length;
  }
  if (!context.mounted) return added.length;
  await applyCollectionTemplate(
    context,
    service,
    collection,
    added,
    auto: collection.autoApply,
    joined: true,
  );
  return added.length;
}

/// 按收藏夹的预设信息改写这些书：[auto] 为 true 时预览后直接应用，否则先请用户确认。
Future<void> applyCollectionTemplate(
  BuildContext context,
  BookCollectionService service,
  BookCollection collection,
  List<String> bookIds, {
  required bool auto,
  bool joined = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final prefix = joined ? '已把 ${bookIds.length} 本加入“${collection.name}”。' : '';
  try {
    final preview = await service.previewFields(
      collection.template,
      bookIds,
      label: collection.name,
    );
    if (preview.changedBooks == 0) {
      messenger?.showSnackBar(
        SnackBar(content: Text('$prefix书籍信息已符合预设，没有改动。')),
      );
      return;
    }
    if (!auto) {
      if (!context.mounted) return;
      final ok = await showFieldPreview(
        context,
        preview,
        title: '套用“${collection.name}”的预设信息',
        subtitle: joined
            ? '书已加入收藏夹。确认后按预设改写下列书籍信息；选“不改信息”只保留分组。'
            : '确认后按预设改写下列书籍信息。',
      );
      if (ok != true) {
        if (joined) {
          messenger?.showSnackBar(SnackBar(content: Text('$prefix书籍信息未改。')));
        }
        return;
      }
    }
    await _apply(service, preview, messenger, prefix: prefix);
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text('$prefix${deskErrorText(e, '预设信息未能套用，书籍信息未改。')}')),
    );
  }
}

/// 批量设类别：预览 → 确认 → 应用（可撤销）。[category] 为空字符串时清空类别。
Future<void> setCategory(
  BuildContext context,
  BookCollectionService service,
  List<String> bookIds,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final category = await showCategoryDialog(context, service, bookIds.length);
  if (category == null || !context.mounted) return;
  try {
    final preview = await service.previewFields(
      {
        'category': category.isEmpty
            ? {'op': 'clear'}
            : {'op': 'set', 'value': category},
      },
      bookIds,
      label: '类别',
    );
    if (preview.changedBooks == 0) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('所选书的类别已是这个值，没有改动。')),
      );
      return;
    }
    if (!context.mounted) return;
    final ok = await showFieldPreview(
      context,
      preview,
      title: category.isEmpty ? '清空类别' : '把类别设为“$category”',
      skipLabel: '取消',
    );
    if (ok != true) return;
    await _apply(service, preview, messenger);
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text(deskErrorText(e, '类别未能设置，书籍信息未改。'))),
    );
  }
}

Future<void> _apply(
  BookCollectionService service,
  BookFieldPreview preview,
  ScaffoldMessengerState? messenger, {
  String prefix = '',
}) async {
  final applied = await service.applyFields(preview);
  messenger?.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('$prefix${applied.message}'),
      action: applied.books.isEmpty
          ? null
          : SnackBarAction(
              label: '撤销',
              onPressed: () async {
                try {
                  final message = await service.undoFields(applied);
                  messenger.showSnackBar(SnackBar(content: Text(message)));
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text(deskErrorText(e, '撤销未完成。'))),
                  );
                }
              },
            ),
    ),
  );
}
