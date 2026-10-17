import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/pending/pending_changes.dart';

/// 模拟一个持有预览的页面：preview 非空时登记为待应用。
class _FakePage extends StatefulWidget {
  const _FakePage({super.key});
  @override
  State<_FakePage> createState() => _FakePageState();
}

class _FakePageState extends State<_FakePage> with PendingReporter<_FakePage> {
  Object? preview;
  int regenerated = 0;
  void rebuild() => setState(() {});
  @override
  Widget build(BuildContext context) {
    reportPending(
      preview == null
          ? null
          : PendingChange(
              token: preview!,
              domain: '文本清理方案',
              summary: '3 处变更',
              location: '/books/b1/cleanup',
              bookId: 'b1',
              discard: () => setState(() => preview = null),
              regenerate: () => setState(() {
                regenerated++;
                preview = Object();
              }),
            ),
    );
    return TextButton(
      onPressed: () => setState(() => preview = Object()),
      child: const Text('生成预览'),
    );
  }
}

void main() {
  testWidgets('G-061 待应用托盘：登记、有效/过期、放弃与页面卸载', (t) async {
    final versions = ValueNotifier<Map<String, String>>({'b1': 'r1'});
    final registry = PendingChangeRegistry(
      version: (id) => versions.value[id],
      bookTitle: (id) => '山海之间',
      versions: versions,
    );
    addTearDown(registry.dispose);
    final opened = <String>[];
    final showPage = ValueNotifier(true);
    final page = GlobalKey<_FakePageState>();
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: PendingScope(
          registry: registry,
          child: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: showPage,
              builder: (_, show, _) =>
                  show ? _FakePage(key: page) : const SizedBox(),
            ),
            bottomNavigationBar: Row(
              children: [
                PendingTrayButton(registry: registry, onOpen: opened.add),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('pending-tray')), findsNothing);

    await t.tap(find.text('生成预览'));
    await t.pumpAndSettle();
    expect(find.text('待应用 1'), findsOneWidget);
    final created = registry.entries.single.created;

    // 同一预览重复报告不重置登记时间。
    page.currentState!.rebuild();
    await t.pumpAndSettle();
    expect(registry.entries.single.created, created);
    expect(registry.entries.single.basis, 'r1');

    await t.tap(find.byKey(const ValueKey('pending-tray')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pending-list')), findsOneWidget);
    expect(find.text('待应用 1 项'), findsOneWidget);
    expect(find.text('文本清理方案'), findsOneWidget);
    expect(find.text('有效'), findsOneWidget);
    expect(find.textContaining('山海之间 · 3 处变更 · 生成于'), findsOneWidget);

    // 书稿版本变化后判为过期；托盘不执行任何应用。
    versions.value = {'b1': 'r2'};
    await t.pumpAndSettle();
    expect(find.text('已过期'), findsOneWidget);
    expect(find.textContaining('之后书稿已修改'), findsOneWidget);

    // 有效时不提供重新生成；过期后可重新生成，生成后回到页面等待确认。
    await t.tap(find.text('重新生成'));
    await t.pumpAndSettle();
    expect(page.currentState!.regenerated, 1);
    expect(opened, ['/books/b1/cleanup']);
    expect(registry.entries.single.basis, 'r2');
    opened.clear();
    await t.tap(find.byKey(const ValueKey('pending-tray')));
    await t.pumpAndSettle();
    expect(find.text('有效'), findsOneWidget);
    expect(find.text('重新生成'), findsNothing);
    await t.tap(find.widgetWithText(OutlinedButton, '打开'));
    await t.pumpAndSettle();
    expect(opened, ['/books/b1/cleanup']);
    expect(find.byKey(const ValueKey('pending-list')), findsNothing);

    // 放弃只清掉页面上的候选。
    await t.tap(find.byKey(const ValueKey('pending-tray')));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, '放弃'));
    await t.pumpAndSettle();
    expect(page.currentState!.preview, isNull);
    expect(registry.entries, isEmpty);
    expect(find.text('没有待应用的预览。'), findsOneWidget);
    await t.tapAt(const Offset(700, 20));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pending-tray')), findsNothing);

    // 页面卸载时撤销登记。
    await t.tap(find.text('生成预览'));
    await t.pumpAndSettle();
    expect(find.text('待应用 1'), findsOneWidget);
    showPage.value = false;
    await t.pumpAndSettle();
    expect(registry.entries, isEmpty);
    expect(find.byKey(const ValueKey('pending-tray')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('没有 PendingScope 时页面报告不做任何事', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: const Scaffold(body: _FakePage()),
      ),
    );
    await t.tap(find.text('生成预览'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
