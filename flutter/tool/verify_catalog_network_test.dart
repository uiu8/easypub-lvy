import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Qidian URL catalog uses transient cookie and reports identity/completeness', () async {
    final cookie = Platform.environment['EASYPUB_QIDIAN_COOKIE'];
    if (cookie == null || cookie.isEmpty) {
      markTestSkipped(
        'set EASYPUB_QIDIAN_COOKIE for the user-authorized live probe',
      );
      return;
    }
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('build/windows/x64/runner/Release/easypub_bridge.dll')
            .absolute
            .path,
      ),
    );
    final raw = await api.catalogRequestText(
      request: jsonEncode({
        'op': 'acquire',
        'source': 'qidian',
        'input': 'https://www.qidian.com/book/1035548629/',
        'use_cache': false,
      }),
      cookie: cookie,
    );
    final value = jsonDecode(raw) as Map<String, dynamic>;
    expect(value['error'], isNull, reason: raw);
    expect(value['stage'], 'candidate');
    final catalog = value['catalog'] as Map<String, dynamic>;
    expect(catalog['book_id'], '1035548629');
    expect((catalog['entries'] as List), isNotEmpty);
    expect([
      'complete',
      'partial',
      'unknown',
    ], contains(catalog['completeness']));
  });
}
