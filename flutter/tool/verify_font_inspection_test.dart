import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('actual font metadata and invalid face through DLL', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    const path = r'C:\Windows\Fonts\arial.ttf';
    expect(File(path).existsSync(), true);
    final report = jsonDecode(
      await api.inspectFontText(
        path: path,
        faceIndex: 0,
        sample: 'ABC\u{10FFFF}',
      ),
    ) as Map;
    expect(report['requested_characters'], 4);
    expect(report['missing_count'], 1);
    expect(report['missing_sample'], ['U+10FFFF']);
    expect(report['bytes'], await File(path).length());
    expect(report['license_confirmation_required'], true);
    expect(report['family'], isNotNull);
    await expectLater(
      api.inspectFontText(path: path, faceIndex: 999, sample: 'ABC'),
      throwsA(anything),
    );
    await expectLater(
      api.inspectFontText(path: 'relative.ttf', faceIndex: 0, sample: 'ABC'),
      throwsA(anything),
    );
    await File('../docs/evidence/r5-font-inspection.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'actual_dll': true,
        'report': report,
        'invalid_face_rejected': true,
        'relative_path_rejected': true,
        'font_copied_or_embedded': false,
      }),
    );
  });
}
