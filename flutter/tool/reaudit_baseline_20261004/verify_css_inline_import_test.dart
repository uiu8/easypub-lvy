import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inline imported stylesheet and images survive offline project', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final dir = Directory(
      '../artifacts/r5-css-inline-import/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    final input = File('${dir.path}/原稿.txt')..writeAsStringSync('第一章 甲\n正文。');
    final original = input.readAsBytesSync();
    final state = PrototypeState(), reopened = PrototypeState();
    addTearDown(state.dispose);
    addTearDown(reopened.dispose);
    await state.importBookOutcome(input.path);
    final id = state.currentId;
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQVDIGAACuAGcVHqFfAAAAAElFTkSuQmCC';
    final percent = base64Decode(png)
        .map((b) => '%${b.toRadixString(16).padLeft(2, '0')}')
        .join();
    final embedded =
        'p{background:url("data:image/png;base64,$png")} h1{background:url("data:image/png,$percent")}';
    final css =
        '@import "data:text/css;charset=utf-8;base64,${base64Encode(utf8.encode(embedded))}" screen;';
    expect(
      await state.production.confirm(
        await state.production.previewChanges({
          id: {
            'op': 'patch',
            'fields': {
              'additional_css': {'op': 'set', 'value': css},
            },
          },
        }),
      ),
      true,
    );
    final ready = await state.production.publicationResources(id);
    final dependencies = ready['manifest']['css_dependencies'] as Map;
    expect(dependencies['rewritten'], true);
    expect(dependencies['issues'], isEmpty);
    expect(dependencies['files'], isEmpty);
    expect(dependencies['resources'], hasLength(3));
    final images = (ready['manifest']['css_media'] as List)
        .where((v) => v['status'] == 'image_decoded')
        .toList();
    expect(images, hasLength(1));
    expect(images.single['width'], 1);
    expect(images.single['height'], 1);
    final project = '${dir.path}/项目.easypub.json';
    await state.saveProjectOutcome(project);
    expect(File(project).existsSync(), true, reason: state.projectStatus);
    await reopened.openProjectOutcome(project);
    final restored = await reopened.production.publicationResources(id);
    expect(
      restored['manifest']['css_dependencies']['root_id'],
      dependencies['root_id'],
    );
    expect(
      restored['manifest']['css_dependencies']['resources'],
      dependencies['resources'],
    );
    expect(reopened.production.settings(id)['additional_css'], css);
    expect(input.readAsBytesSync(), original);
    File('../artifacts/reaudit-20261004/baseline/evidence/r5-css-inline-import.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'passed_partial': true,
        'project': project,
        'resources': dependencies['resources'],
        'checks': [
          'actual DLL inline base64 and percent-encoded PNG',
          'inline stylesheet import with nested inline images',
          'content deduplication',
          'decoded pixels',
          'no external file dependency',
          'project offline snapshot and reopen',
          'source unchanged',
        ],
        'not_verified': [
          'inline fonts actual DLL',
          'SVG/WOFF',
          'all inline stylesheet combinations',
          'reader rendering',
          'packaged executable',
        ],
      }),
    );
  });
}
