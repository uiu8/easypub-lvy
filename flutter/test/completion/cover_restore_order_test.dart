import 'dart:async';

import 'package:easypub_desktop/application/book_information_service.dart';
import 'package:easypub_desktop/application/workspace_autosave_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/metadata/cover_image_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class PendingCoverSession extends BookInformationSession {
  final requests = <Completer<CoverImageEvidence>>[];
  @override
  Future<CoverImageEvidence> inspectImage(String path) {
    final request = Completer<CoverImageEvidence>();
    requests.add(request);
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CoverDrafts implements WorkspaceAutosaveService {
  Map<String, dynamic>? draft = {'path': 'old.png', 'fit': 'contain'};
  @override
  Map<String, dynamic>? readDraft(String key) => draft;
  @override
  void writeDraft(String key, Map<String, dynamic>? value) => draft = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final failure in [false, true]) {
    testWidgets('封面草稿恢复期间禁用选择，关闭后的结果不污染新窗口 failure=$failure', (t) async {
      t.view.physicalSize = const Size(1100, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final session = PendingCoverSession();
      final drafts = CoverDrafts();
      var picked = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => CoverImageDialog(
                    session: session,
                    initialFit: 'contain',
                    autosave: drafts,
                    draftKey: 'test',
                    pickImage: () async {
                      picked++;
                      return null;
                    },
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      DeskButton button(String text) =>
          t.widget<DeskButton>(find.widgetWithText(DeskButton, text));
      expect(session.requests, hasLength(1));
      expect(button('浏览图片').onPressed, isNull);
      expect(button('使用此图片').onPressed, isNull);
      expect(button('进入裁切调整').onPressed, isNull);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      if (failure) {
        session.requests.first.completeError(StateError('late old check'));
      } else {
        session.requests.first.complete(
          const CoverImageEvidence('old.png', 'old', 1, 1, 10, 'png'),
        );
      }
      await t.pumpAndSettle();
      expect(find.text('上次选择的图片不可用，请重新选择。'), findsNothing);
      expect(find.text('old.png'), findsNothing);
      expect(button('浏览图片').onPressed, isNotNull);
      await t.tap(find.text('浏览图片'));
      await t.pumpAndSettle();
      expect(picked, 1);
      expect(drafts.draft, isNull);
      expect(t.takeException(), isNull);
    });
  }
}
