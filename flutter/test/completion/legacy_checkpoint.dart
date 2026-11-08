// 造出旧版“保存编辑快照”留下的历史。界面已经没有这个功能，但旧项目还要能读，
// 相关路径靠这里继续被端到端测试覆盖。
import 'dart:convert';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;

Future<void> legacyCheckpoint(PrototypeState state, String id) async {
  final source = state.shelf.books.firstWhere((b) => b.id == id).source!;
  final result = jsonDecode(
    await api.editEffectiveDraft(
      sourceId: source.sourceId,
      revision: source.revision,
      baseJson: jsonEncode(state.manuscript.effectiveBase(id)),
      draftJson: jsonEncode(state.manuscript.effectiveHistories[id]),
      commandJson: jsonEncode({
        'op': 'checkpoint',
        'directory': '${state.settingsDirectory}/edit-checkpoints',
      }),
    ),
  ) as Map;
  state.change(
    () => state.manuscript.effectiveHistories[id] = (result['history'] as Map)
        .cast<String, dynamic>(),
  );
}
