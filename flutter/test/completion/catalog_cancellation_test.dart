import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/infrastructure/native_catalog_requests.dart';

void main() {
  test('cancel reaches active native request, rejects late result and permits restart', () async {
    final started = Completer<void>(), response = Completer<String>();
    final cancelled = <String>[];
    var count = 0;
    final requests = NativeCatalogRequests(
      invoke: ({required request, required cookie}) async {
        final p = jsonDecode(request) as Map;
        if (p['op'] == 'begin_request') {
          expect(cookie, isEmpty);
          return jsonEncode({'request_id': 'id-${++count}'});
        }
        if (p['op'] == 'cancel_request') {
          expect(cookie, isEmpty);
          cancelled.add(p['request_id'] as String);
          return '{}';
        }
        expect(cookie, 'transient-cookie');
        if (count == 1) {
          started.complete();
          return response.future;
        }
        return '{"stage":"candidate"}';
      },
    );
    final first = requests.request(
      request: '{"op":"acquire"}',
      cookie: 'transient-cookie',
    );
    final failed = expectLater(first, throwsFormatException);
    await started.future;
    requests.cancel();
    expect(cancelled, contains('id-1'));
    response.complete('{"stage":"candidate"}');
    await failed;
    expect(
      await requests.request(
        request: '{"op":"acquire"}',
        cookie: 'transient-cookie',
      ),
      contains('candidate'),
    );
    expect(cancelled, contains('id-2'));
  });
  test(
    'cancellation during native registration prevents acquisition entirely',
    () async {
      final registration = Completer<String>();
      final calls = <String>[];
      final requests = NativeCatalogRequests(
        invoke: ({required request, required cookie}) async {
          final p = jsonDecode(request) as Map;
          calls.add(p['op'] as String);
          if (p['op'] == 'begin_request') return registration.future;
          expect(p['op'], 'cancel_request');
          return '{}';
        },
      );
      final pending = requests.request(request: '{"op":"acquire"}', cookie: '');
      final failed = expectLater(pending, throwsFormatException);
      requests.cancel();
      registration.complete('{"request_id":"late"}');
      await failed;
      expect(calls, ['begin_request', 'cancel_request']);
    },
  );
  test(
    'native bridge releases tokens and rejects a cancelled late acquisition',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final begin = jsonDecode(
        await api.catalogRequestText(
          request: '{"op":"begin_request"}',
          cookie: '',
        ),
      ) as Map;
      final id = begin['request_id'];
      expect(id, isA<String>());
      await api.catalogRequestText(
        request: jsonEncode({'op': 'cancel_request', 'request_id': id}),
        cookie: '',
      );
      final result = jsonDecode(
        await api.catalogRequestText(
          request: jsonEncode({
            'op': 'acquire',
            'source': 'paste',
            'input': '第一章 测试',
            'request_id': id,
          }),
          cookie: '',
        ),
      ) as Map;
      expect(result['reason'], 'catalog_cancelled');
      final requests = NativeCatalogRequests();
      for (var i = 0; i < 70; i++) {
        final candidate = jsonDecode(
          await requests.request(
            request: jsonEncode({
              'op': 'acquire',
              'source': 'paste',
              'input': '第一章 测试',
              'title': '取消测试',
            }),
            cookie: '',
          ),
        ) as Map;
        expect(candidate['stage'], 'candidate');
      }
    },
  );
}
