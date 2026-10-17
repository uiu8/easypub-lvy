import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/chapters/outline.dart';
import 'package:easypub_desktop/desk/chapters/chapter_view_state.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class TreeSession extends Fake implements ChapterSession {
  final offsets = <int>[];
  bool fail = false;
  String guard = 'first';
  final nodes = List.generate(
    85,
    (i) => ChapterNode(
      'n$i',
      i == 0
          ? '第一卷'
          : i == 41
          ? '第二卷'
          : '第$i章 标题$i',
      i == 0 || i == 41 ? 'volume' : 'chapter',
      i == 0 || i == 41 ? 0 : 1,
      i * 10 + 1,
      true,
    ),
  );
  ChapterPage at(int offset) => ChapterPage(
    nodes.skip(offset).take(30).toList(),
    nodes.length,
    offset,
    guard,
  );
  @override
  Future<ChapterPage> read(
    int offset, {
    bool includeBody = false,
    String? preferredNodeId,
  }) async {
    offsets.add(offset);
    if (fail) throw const FormatException('读取暂时失败');
    return at(offset);
  }
}

void main() {
  testWidgets(
    'returning to a book restores tree search, folding and scroll; explicit targets still reveal',
    (tester) async {
      final session = TreeSession();
      final view = ChapterTreeViewState();
      Future<void> open({bool restore = true, String selected = 'n1'}) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: deskTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 330,
                height: 580,
                child: ChapterOutline(
                  session: session,
                  snapshot: session.at(0),
                  selectedId: selected,
                  viewState: view,
                  restoreNavigation: restore,
                  enabled: true,
                  onSelect: (_, _) async {},
                  onMenu: (_, _, _) async {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> leave() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }

      await open(selected: 'n0');
      tester
          .widget<Focus>(find.byKey(const ValueKey('chapter-tree-keyboard')))
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(view.collapsed, contains('n0'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(view.collapsed, isNot(contains('n0')));
      await tester.tap(find.byTooltip('收起卷').first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('tree-node-n65')),
        350,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      final offset = view.scrollOffset;
      expect(offset, greaterThan(0));
      await leave();
      await open();
      expect(view.collapsed, contains('n0'));
      expect(view.scrollOffset, closeTo(offset, 1));
      expect(
        find.byKey(const ValueKey('tree-node-n65')).hitTestable(),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '标题84');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await leave();
      await open();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '标题84',
      );
      expect(find.text('第84章 标题84'), findsOneWidget);
      await leave();
      await open(restore: false);
      expect(
        find.byKey(const ValueKey('tree-node-n1')).hitTestable(),
        findsOneWidget,
      );
      expect(view.query, isEmpty);
      expect(view.collapsed, isNot(contains('n0')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'continuous scrolling preserves node owners, folds volumes and searches the entire book',
    (tester) async {
      final session = TreeSession();
      ChapterPage? selectedPage;
      ChapterNode? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 330,
                height: 580,
                child: ChapterOutline(
                  session: session,
                  snapshot: session.at(0),
                  selectedId: 'n1',
                  enabled: true,
                  onSelect: (p, n) async {
                    selectedPage = p;
                    selected = n;
                  },
                  onMenu: (_, _, _) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('下一页章节'), findsNothing);
      tester
          .widget<Focus>(find.byKey(const ValueKey('chapter-tree-keyboard')))
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(selected!.id, 'n2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(selected!.id, 'n0');
      await tester.tap(find.byType(TextField));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(
        selected!.id,
        'n0',
        reason: 'search editing must not select chapters',
      );
      await tester.tap(find.byTooltip('收起卷').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tree-node-n1')), findsNothing);
      expect(find.text('第二卷'), findsOneWidget);
      await tester.tap(find.byTooltip('展开卷').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tree-node-n1')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('tree-node-n65')),
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tree-node-n65')));
      expect(selected!.id, 'n65');
      expect(selectedPage!.offset, 60);
      await tester.enterText(find.byType(TextField), '标题84');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('第84章 标题84'), findsOneWidget);
      expect(find.text('1 个匹配 · 已查 85/85'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed incremental load can retry without losing the existing tree',
    (tester) async {
      final session = TreeSession()..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 330,
              height: 580,
              child: ChapterOutline(
                session: session,
                snapshot: session.at(0),
                selectedId: 'n1',
                enabled: true,
                onSelect: (_, _) async {},
                onMenu: (_, _, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '标题84');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('重试加载'), findsOneWidget);
      session.fail = false;
      await tester.tap(find.text('重试加载'));
      await tester.pumpAndSettle();
      expect(find.text('第84章 标题84'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
