// 附页模板管理（V56，META-049）：全局模板，所有书共用。保存失败时保留原设置；
// 套用后的附页与模板脱钩，改模板或删模板不影响已套用的书。
import 'package:flutter/material.dart';

import '../../application/supplemental_page_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'supplemental_pages_card.dart';

const supplementalPlaceholders = [
  '{书名}',
  '{作者}',
  '{译者}',
  '{年份}',
  '{出版社}',
  '{出版日期}',
  '{ISBN}',
  '{分类}',
  '{系列}',
  '{系列序号}',
  '{主题}',
  '{语言}',
  '{简介}',
];

class SupplementalTemplatesDialog extends StatefulWidget {
  const SupplementalTemplatesDialog({super.key, required this.service});
  final SupplementalTemplateService service;
  @override
  State<SupplementalTemplatesDialog> createState() =>
      _SupplementalTemplatesDialogState();
}

class _SupplementalTemplatesDialogState
    extends State<SupplementalTemplatesDialog> {
  SupplementalTemplateSnapshot? snapshot;

  /// 正在编辑的模板 id；null 表示新建。
  String? selected;
  final name = TextEditingController();
  final title = TextEditingController();
  final body = TextEditingController();
  SupplementalPageKind kind = SupplementalPageKind.copyright;
  SupplementalPagePosition position = SupplementalPagePosition.front;
  bool includeToc = true;
  bool busy = false;
  String message = '';

  @override
  void initState() {
    super.initState();
    // 首帧之后再读：读取全局设置会发通知，不能发生在构建期间。
    busy = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) load();
    });
  }

  Future<void> load() => run(() async {
    final next = await widget.service.list();
    if (!mounted) return;
    setState(() => snapshot = next);
    if (next.templates.isNotEmpty) {
      select(next.templates.first);
    } else {
      startNew();
    }
  });

  @override
  void dispose() {
    name.dispose();
    title.dispose();
    body.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = supplementalError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void select(SupplementalTemplate t) => setState(() {
    selected = t.id;
    name.text = t.name;
    title.text = t.content.title;
    body.text = t.content.body;
    kind = t.content.kind;
    position = t.content.position;
    includeToc = t.content.includeToc;
  });

  void startNew() => setState(() {
    selected = null;
    name.text = '';
    title.text = '{书名}版权信息';
    body.text = '书名：{书名}\n作者：{作者}\n\n© {年份} 保留所有权利';
    kind = SupplementalPageKind.copyright;
    position = SupplementalPagePosition.front;
    includeToc = true;
  });

  void insert(String placeholder) {
    final s = body.selection;
    final text = body.text;
    final start = s.isValid ? s.start : text.length;
    final end = s.isValid ? s.end : text.length;
    body.value = TextEditingValue(
      text: text.replaceRange(start, end, placeholder),
      selection: TextSelection.collapsed(offset: start + placeholder.length),
    );
    setState(() {});
  }

  Future<void> save() => run(() async {
    final next = await widget.service.save(
      snapshot!,
      id: selected,
      name: name.text.trim(),
      content: SupplementalPageContent(
        kind: kind,
        position: position,
        title: title.text,
        body: body.text,
        includeToc: includeToc,
      ),
    );
    if (!mounted) return;
    final saved = next.templates.firstWhere(
      (t) => selected == null
          ? t.name.toLowerCase() == name.text.trim().toLowerCase()
          : t.id == selected,
    );
    setState(() {
      snapshot = next;
      message = '已保存模板';
    });
    select(saved);
  });

  Future<void> delete() async {
    final id = selected;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => DeskAlert(
        title: const Text('删除模板'),
        content: Text('删除模板“${name.text}”？已经套用到书里的附页不受影响。'),
        actions: [
          DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
          DeskButton(
            '删除',
            key: const ValueKey('supplemental-template-delete-confirm'),
            dangerous: true,
            primary: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await run(() async {
      final next = await widget.service.delete(snapshot!, id);
      if (!mounted) return;
      setState(() {
        snapshot = next;
        message = '已删除模板';
      });
      if (next.templates.isNotEmpty) {
        select(next.templates.first);
      } else {
        startNew();
      }
    });
  }

  Widget sidebar() {
    final d = context.desk;
    final list = snapshot?.templates ?? const <SupplementalTemplate>[];
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final t in list)
                  Material(
                    color: t.id == selected ? d.sunken : d.surface,
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      key: ValueKey(('supplemental-template-item', t.id)),
                      borderRadius: BorderRadius.circular(6),
                      onTap: busy ? null : () => select(t),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.name,
                              overflow: TextOverflow.ellipsis,
                              style: ui(13, c: d.ink),
                            ),
                            Text(
                              '${supplementalPageLabels[t.content.kind]} · '
                              '${supplementalPositionLabels[t.content.position]}',
                              style: ui(11, c: d.ink3),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (list.isEmpty && snapshot != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('还没有模板', style: ui(12, c: d.ink3)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          DeskButton(
            '新建模板',
            key: const ValueKey('supplemental-template-new'),
            icon: Icons.add_rounded,
            onPressed: busy ? null : startNew,
          ),
        ],
      ),
    );
  }

  Widget editor() {
    final d = context.desk;
    return ListView(
      children: [
        const DeskLabel('模板名称'),
        TextField(
          key: const ValueKey('supplemental-template-name'),
          controller: name,
          enabled: !busy,
          maxLines: 1,
          onChanged: (_) => setState(() {}),
          style: ui(13, c: d.ink),
          decoration: deskInput(context, hint: '例如：我的版权页'),
        ),
        const SizedBox(height: 10),
        const DeskLabel('类型'),
        DeskSegmented<SupplementalPageKind>(
          value: kind,
          options: supplementalPageLabels,
          onChanged: busy ? null : (v) => setState(() => kind = v),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            DeskSegmented<SupplementalPagePosition>(
              value: position,
              options: supplementalPositionLabels,
              onChanged: busy ? null : (v) => setState(() => position = v),
            ),
            const SizedBox(width: 16),
            Checkbox(
              value: includeToc,
              visualDensity: VisualDensity.compact,
              onChanged: busy
                  ? null
                  : (v) => setState(() => includeToc = v ?? false),
            ),
            Text('进目录', style: ui(12.5, c: d.ink)),
          ],
        ),
        const SizedBox(height: 10),
        const DeskLabel('标题（可含占位符）'),
        TextField(
          key: const ValueKey('supplemental-template-title'),
          controller: title,
          enabled: !busy,
          maxLines: 1,
          style: ui(13, c: d.ink),
          decoration: deskInput(context),
        ),
        const SizedBox(height: 10),
        const DeskLabel('正文'),
        TextField(
          key: const ValueKey('supplemental-template-body'),
          controller: body,
          enabled: !busy,
          minLines: 6,
          maxLines: 10,
          onChanged: (_) => setState(() {}),
          style: ui(13, c: d.ink, h: 1.5),
          decoration: deskInput(context),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('插入：', style: ui(11.5, c: d.ink3)),
            for (final p in supplementalPlaceholders)
              Material(
                color: d.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                  side: BorderSide(color: d.lineStrong),
                ),
                child: InkWell(
                  key: ValueKey(('supplemental-placeholder', p)),
                  borderRadius: BorderRadius.circular(5),
                  onTap: busy ? null : () => insert(p),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(p, style: ui(11.5, c: d.ink2)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '套用时占位符换成当前书的信息，书籍信息为空的换成空；不认识的占位符原样保留并提示。',
          style: ui(11.5, c: d.ink3, h: 1.5),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: '附页模板',
      subtitle: '所有书共用；套用后与模板脱钩，之后改模板不影响已套用的书。',
      closeTooltip: '关闭',
      width: 760,
      height: 600,
      busy: busy,
      footerLeft: message.isEmpty
          ? null
          : Text(
              message,
              style: ui(12, c: message.startsWith('已') ? d.ink2 : d.pen),
            ),
      actions: [
        if (selected != null)
          DeskButton(
            '删除模板',
            key: const ValueKey('supplemental-template-delete'),
            quiet: true,
            dangerous: true,
            onPressed: busy ? null : delete,
          ),
        DeskButton(
          '保存模板',
          key: const ValueKey('supplemental-template-save'),
          primary: true,
          disabledReason: '填写模板名称和正文',
          onPressed:
              busy ||
                  snapshot == null ||
                  name.text.trim().isEmpty ||
                  body.text.trim().isEmpty
              ? null
              : save,
        ),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sidebar(),
          VerticalDivider(width: 24, color: d.line),
          Expanded(child: editor()),
        ],
      ),
    );
  }
}
