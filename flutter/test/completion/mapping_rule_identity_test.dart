import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';

void main() {
  test('new identities persist across edits and revisions follow content', () {
    final rule = MappingRule.create(Directory.systemTemp.path, {
      'author': {'op': 'set', 'value': '作者'},
    });
    final restored = MappingRule.fromJson(rule.toJson());
    expect(restored.id, rule.id);
    expect(restored.version, rule.version);
    final changed = restored.revised('${Directory.systemTemp.path}/next', {
      'author': {'op': 'set', 'value': '新作者'},
    });
    expect(changed.id, rule.id);
    expect(changed.version, isNot(rule.version));
    expect(
      changed.revised(changed.folder, changed.fields).version,
      changed.version,
    );
    expect(MappingRule.create(rule.folder, rule.fields).id, isNot(rule.id));
    expect(
      () =>
          MappingRule.fromJson({...changed.toJson(), 'version': rule.version}),
      throwsFormatException,
    );
  });
  test(
    'legacy identities are deterministic and serialization order is irrelevant',
    () {
      final a = MappingRule(Directory.systemTemp.path, {
        'author': {'op': 'set', 'value': '甲'},
        'title': {'op': 'keep'},
      });
      final b = MappingRule(Directory.systemTemp.path, {
        'title': {'op': 'keep'},
        'author': {'value': '甲', 'op': 'set'},
      });
      expect(a.id, b.id);
      expect(a.version, b.version);
      expect(a.revised('${a.folder}/changed', a.fields).id, a.id);
    },
  );
}
