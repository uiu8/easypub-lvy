import 'dart:async';

import 'package:easypub_desktop/application/book_information_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/shell/quick_layout_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class DelayedLayout extends LayoutSession {
  final requests = <Completer<BookInformationPreview>>[];
  BookInformationPreview? applied;
  @override
  List<LayoutPreset> get presets => [
    LayoutPreset('A', {}),
    LayoutPreset('B', {}),
  ];
  @override
  Future<LayoutPreset> builtinPreset() async => LayoutPreset('默认', {});
  @override
  Future<List<LayoutPreset>> readGlobalPresets() async => [];
  @override
  Future<BookInformationPreview> previewPreset(String name) {
    final result = Completer<BookInformationPreview>();
    requests.add(result);
    return result.future;
  }

  @override
  Future<void> apply(BookInformationPreview preview) async {
    applied = preview;
  }

  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class LayoutLibrary implements LibraryService {
  LayoutLibrary(this.session);
  final DelayedLayout session;
  @override
  LayoutSession openLayout(String id) => session;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('快速排版 A-B-A 旧成功和旧失败不覆盖最新选择', (t) async {
    t.view.physicalSize = const Size(1100, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final session = DelayedLayout();
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => QuickLayoutDialog(
                  library: LayoutLibrary(session),
                  book: const BookSummary(
                    id: 'book',
                    title: '测试',
                    author: '',
                    path: '',
                    format: 'TXT',
                    chapters: 1,
                    status: '',
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    for (final name in ['A', 'B', 'A']) {
      await t.tap(find.byKey(ValueKey('quick-layout-本项目预设-$name')));
      await t.pump();
      if (session.requests.length < 3) {
        await t.tap(find.byKey(const ValueKey('quick-layout-back')));
        await t.pump();
      }
    }
    final latest = BookInformationPreview(
      {'font_size': 100},
      {'font_size': 130},
      ['font_size'],
    );
    session.requests[2].complete(latest);
    await t.pumpAndSettle();
    session.requests[1].completeError(StateError('old failure'));
    session.requests[0].complete(
      BookInformationPreview({'font_size': 100}, {'font_size': 110}, [
        'font_size',
      ]),
    );
    await t.pumpAndSettle();
    expect(find.text('应用“A”'), findsOneWidget);
    final apply = find.byKey(const ValueKey('quick-layout-apply'));
    expect(t.widget<DeskButton>(apply).onPressed, isNotNull);
    await t.tap(apply);
    await t.pumpAndSettle();
    expect(identical(session.applied, latest), isTrue);
    expect(t.takeException(), isNull);
  });
}
