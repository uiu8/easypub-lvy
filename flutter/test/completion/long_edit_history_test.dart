import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/effective_history.dart';

import 'library_removal_test.dart' as fixtures;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('改过 100 次以上的书继续编辑、撤销、保存重开都正常，步骤只存一份', () async {
    final (state, library, root) = await fixtures.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = library.books.value.first.id;
    library.selectBook(id);
    final chapter = library.openChapters(id);
    final nodeId = (await chapter.read(0)).nodes.first.id;
    for (var n = 1; n <= 130; n++) {
      await chapter.confirm(
        await chapter.preview(
          await chapter.read(0),
          RenameChapter(nodeId, '第一章 第$n次'),
        ),
      );
    }
    final history = state.manuscript.effectiveHistories[id]!;
    expect(state.manuscript.effectiveSelection(id)!['actions'], hasLength(130));
    expect((history['history'] as List).length, 51, reason: '撤销状态数量不变');
    expect(history['logs'], hasLength(1), reason: '所有状态共用一份步骤');
    expect((await chapter.read(0)).nodes.first.title, '第一章 第130次');

    final records = library.openChangeHistory().records(id);
    expect(records.where((r) => r.domain == '章节'), isNotEmpty);

    expect(
      (await library.saveProject('$root/long.easypub.json')).succeeded,
      true,
    );
    final saved =
        jsonDecode(await File('$root/long.easypub.json').readAsString()) as Map;
    final book = (saved['books'] as List).firstWhere(
      (b) => b['effective_history'] != null,
    );
    expect(
      currentEffectiveRequest(book['effective_history'] as Map)['actions'],
      hasLength(130),
    );
  });

  test('旧版保存的历史也能读出步骤', () {
    final history = {
      'cursor': 1,
      'history': [
        {
          'request': {'base_id': 'a', 'actions': <dynamic>[]},
        },
        {
          'request': {
            'base_id': 'a',
            'actions': [
              {'kind': 'rename'},
            ],
          },
        },
      ],
    };
    expect(currentEffectiveRequest(history)['actions'], hasLength(1));
    expect(effectiveRequest(history, 0)['actions'], isEmpty);
  });

  test('新格式按条数取前缀，没有步骤的状态取到空列表', () {
    final history = {
      'cursor': 2,
      'logs': [
        [
          {'kind': 'a'},
          {'kind': 'b'},
          {'kind': 'c'},
        ],
      ],
      'history': [
        {
          'request': {'base_id': 'x', 'log': 0, 'count': 0},
        },
        {
          'request': {'base_id': 'x', 'log': 0, 'count': 2},
        },
        {
          'request': {
            'base_id': 'x',
            'log': 0,
            'count': 3,
            'checkpoint': {'digest': 'd'},
          },
        },
      ],
    };
    expect(effectiveRequest(history, 0)['actions'], isEmpty);
    expect(effectiveRequest(history, 1)['actions'], hasLength(2));
    expect(effectiveRequest(history, 1).containsKey('checkpoint'), false);
    expect(currentEffectiveRequest(history)['checkpoint'], {'digest': 'd'});
  });
}
