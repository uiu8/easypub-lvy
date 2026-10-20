// 收藏夹弹窗（V84，LIB-119–124）：新建 / 编辑收藏夹（名称、预设信息、加入后直接套用）、
// 书籍信息改动预览、批量设类别。预设信息与元数据映射用同一套应用方式。
import 'package:flutter/material.dart';

import '../../application/book_collection_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';

const _ops = <String, String>{
  'keep': '不改',
  'fill_empty': '仅填空值',
  'set': '设为指定值',
  'clear': '清空',
};

/// 新建（[existing] 为空）或编辑收藏夹；返回保存后的收藏夹，取消返回 null。
Future<BookCollection?> showCollectionEditor(
  BuildContext context,
  BookCollectionService service, {
  BookCollection? existing,
  String initialName = '',
}) => showDialog<BookCollection>(
  context: context,
  builder: (_) => _CollectionEditor(
    service: service,
    existing: existing,
    initialName: initialName,
  ),
);

class _CollectionEditor extends StatefulWidget {
  const _CollectionEditor({
    required this.service,
    this.existing,
    this.initialName = '',
  });
  final BookCollectionService service;
  final BookCollection? existing;
  final String initialName;
  @override
  State<_CollectionEditor> createState() => _CollectionEditorState();
}

class _CollectionEditorState extends State<_CollectionEditor> {
  late final name = TextEditingController(
    text: widget.existing?.name ?? widget.initialName,
  );
  late final ops = <String, String>{
    for (final key in collectionTemplateFields.keys)
      key: widget.existing?.template[key]?['op'] ?? 'keep',
  };
  late final values = <String, TextEditingController>{
    for (final key in collectionTemplateFields.keys)
      key: TextEditingController(
        text: widget.existing?.template[key]?['value'] ?? '',
      ),
  };
  late bool autoApply = widget.existing?.autoApply ?? true;
  String error = '';

  @override
  void dispose() {
    name.dispose();
    for (final c in values.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, Map<String, String>> get template => {
    for (final key in collectionTemplateFields.keys)
      if (ops[key] != 'keep')
        key: {
          'op': ops[key]!,
          if (ops[key] == 'set' || ops[key] == 'fill_empty')
            'value': values[key]!.text.trim(),
        },
  };

  void save() {
    final nameError = collectionNameError(
      name.text,
      widget.service.collections.value,
      exceptId: widget.existing?.id,
    );
    final missing = [
      for (final e in template.entries)
        if ((e.value['op'] == 'set' || e.value['op'] == 'fill_empty') &&
            (e.value['value'] ?? '').isEmpty)
          collectionTemplateFields[e.key]!,
    ];
    if (nameError != null || missing.isNotEmpty) {
      setState(
        () => error = nameError ?? '请填写${missing.join('、')}的预设值，或改为“不改”。',
      );
      return;
    }
    try {
      final existing = widget.existing;
      final saved = existing == null
          ? widget.service.createCollection(
              name.text,
              template: template,
              autoApply: autoApply,
            )
          : (existing.copyWith(
              name: name.text.trim(),
              template: template,
              autoApply: autoApply,
            ));
      if (existing != null) widget.service.updateCollection(saved);
      Navigator.pop(context, saved);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: widget.existing == null ? '新建收藏夹' : '编辑收藏夹',
      subtitle: '收藏夹只是分组：删除收藏夹或移出书都不会删书。可选填一份预设信息，书加入时按它补全。',
      closeTooltip: '取消',
      width: 560,
      footerLeft: error.isEmpty
          ? null
          : Text(
              error,
              key: const ValueKey('collection-editor-error'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: d.pen),
            ),
      actions: [
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          widget.existing == null ? '新建' : '保存',
          key: const ValueKey('collection-save'),
          primary: true,
          onPressed: save,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DeskLabel('名称'),
          TextField(
            key: const ValueKey('collection-name'),
            controller: name,
            autofocus: true,
            maxLength: 64,
            style: ui(13, c: d.ink),
            decoration: deskInput(
              context,
              hint: '例如：武侠、待校对、某作者全集',
            ).copyWith(counterText: ''),
            onSubmitted: (_) => save(),
          ),
          const SizedBox(height: 14),
          const DeskLabel('预设信息（加入收藏夹时套用）'),
          for (final entry in collectionTemplateFields.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(entry.value, style: ui(12.5, c: d.ink)),
                  ),
                  SizedBox(
                    width: 132,
                    child: DeskFilter<String>(
                      key: ValueKey('collection-op-${entry.key}'),
                      value: ops[entry.key],
                      onChanged: (v) =>
                          setState(() => ops[entry.key] = v ?? 'keep'),
                      items: [
                        for (final op in _ops.entries)
                          DropdownMenuItem(
                            value: op.key,
                            child: Text(op.value),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: ValueKey('collection-value-${entry.key}'),
                      controller: values[entry.key],
                      enabled:
                          ops[entry.key] == 'set' ||
                          ops[entry.key] == 'fill_empty',
                      style: ui(13, c: d.ink),
                      decoration: deskInput(
                        context,
                        hint: ops[entry.key] == 'clear'
                            ? '加入时清空这一项'
                            : ops[entry.key] == 'keep'
                            ? '不改这一项'
                            : '预设值',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          InkWell(
            onTap: () => setState(() => autoApply = !autoApply),
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                Switch(
                  key: const ValueKey('collection-auto-apply'),
                  value: autoApply,
                  onChanged: (v) => setState(() => autoApply = v),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '书加入后直接套用（不再逐次预览；套用后可在提示里撤销）',
                    style: ui(12.5, c: d.ink),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const DeskNote('“仅填空值”只补书里还空着的项，最稳妥；“设为指定值”会覆盖原有内容。'),
        ],
      ),
    );
  }
}

String _value(Object? v) {
  final text = '${v ?? ''}'.trim();
  return text.isEmpty ? '（空）' : text;
}

/// 书籍信息改动预览；确认返回 true。
Future<bool?> showFieldPreview(
  BuildContext context,
  BookFieldPreview preview, {
  required String title,
  String subtitle = '',
  String applyLabel = '应用',
  String skipLabel = '不改信息',
}) => showDialog<bool>(
  context: context,
  builder: (dialogContext) {
    final d = dialogContext.desk;
    final changed = preview.items.where((i) => i.changed.isNotEmpty).toList();
    return DeskDialog(
      title: title,
      subtitle: subtitle.isEmpty ? null : subtitle,
      closeTooltip: skipLabel,
      width: 620,
      height: 480,
      footerLeft: Text(
        '将改 ${changed.length} 本 · 不变 ${preview.items.length - changed.length} 本',
        style: ui(12, c: d.ink3),
      ),
      actions: [
        DeskButton(
          skipLabel,
          quiet: true,
          onPressed: () => Navigator.pop(dialogContext, false),
        ),
        DeskButton(
          applyLabel,
          key: const ValueKey('field-preview-apply'),
          primary: true,
          onPressed: changed.isEmpty
              ? null
              : () => Navigator.pop(dialogContext, true),
        ),
      ],
      child: DeskListBox(
        child: ListView.builder(
          itemCount: changed.length,
          itemBuilder: (_, i) {
            final item = changed[i];
            return Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: d.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(13, w: 600, c: d.ink),
                  ),
                  for (final key in item.changed)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '${collectionTemplateFields[key] ?? key}：'
                        '${_value(item.before[key])} → ${_value(item.after[key])}',
                        style: ui(12, c: d.ink2),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  },
);

/// 批量设类别：输入或从已有类别中选；返回类别文字（空字符串表示清空），取消返回 null。
Future<String?> showCategoryDialog(
  BuildContext context,
  BookCollectionService service,
  int count,
) => showDialog<String>(
  context: context,
  builder: (_) =>
      _CategoryDialog(known: service.knownCategories(), count: count),
);

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({required this.known, required this.count});
  final List<String> known;
  final int count;
  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: '设置类别',
      subtitle: '把所选 ${widget.count} 本书的“类别”设为同一个值；应用前先预览改动。',
      closeTooltip: '取消',
      width: 460,
      actions: [
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          '清空类别',
          quiet: true,
          onPressed: () => Navigator.pop(context, ''),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: input,
          builder: (_, value, _) => DeskButton(
            '预览',
            key: const ValueKey('category-preview'),
            primary: true,
            onPressed: value.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, value.text.trim()),
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DeskLabel('类别'),
          TextField(
            key: const ValueKey('category-input'),
            controller: input,
            autofocus: true,
            style: ui(13, c: d.ink),
            decoration: deskInput(context, hint: '例如：武侠、科幻、历史'),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
            },
          ),
          if (widget.known.isNotEmpty) ...[
            const SizedBox(height: 12),
            const DeskLabel('书库里已有的类别'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in widget.known.take(24))
                  ActionChip(
                    label: Text(c),
                    onPressed: () => setState(() {
                      input.text = c;
                      input.selection = TextSelection.collapsed(
                        offset: c.length,
                      );
                    }),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
