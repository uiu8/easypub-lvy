import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as api;

typedef CatalogWireRequest = Future<String> Function({
  required String request,
  required String cookie,
});

/// Owns native acquisition lifetimes. Only acquisition and explicit credential
/// save receive window input; status/cancellation never expose stored plaintext.
class NativeCatalogRequests {
  NativeCatalogRequests({CatalogWireRequest? invoke})
    : _invoke = invoke ?? api.catalogRequestText;
  final CatalogWireRequest _invoke;
  final _active = <String>{};
  int _generation = 0;

  void cancel() {
    _generation++;
    for (final id in _active.toList()) {
      unawaited(_release(id));
    }
  }

  Future<void> _release(String id) async {
    _active.remove(id);
    try {
      await _invoke(
        request: jsonEncode({'op': 'cancel_request', 'request_id': id}),
        cookie: '',
      );
    } catch (_) {
      // A transport shutdown must not replace the acquisition's result/error.
    }
  }

  Future<String> request({
    required String request,
    required String cookie,
  }) async {
    final enteringGeneration = _generation;
    final payload = request.length < 65536
        ? _decodeCatalogJson(request)
        : await decodeCatalogResponse(request);
    if (payload['op'] != 'acquire') {
      return _invoke(request: request, cookie: cookie);
    }
    if (enteringGeneration != _generation) {
      throw const FormatException('目录请求已取消。');
    }
    cancel();
    final ticket = _generation;
    final registration = jsonDecode(
      await _invoke(request: jsonEncode({'op': 'begin_request'}), cookie: ''),
    ) as Map;
    final id = registration['request_id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('目录服务忙碌，请稍后重试。');
    }
    _active.add(id);
    try {
      if (ticket != _generation) {
        throw const FormatException('目录请求已取消。');
      }
      final encoded = await encodeCatalogRequest({
        ...payload,
        'request_id': id,
      });
      if (ticket != _generation) {
        throw const FormatException('目录请求已取消。');
      }
      final result = await _invoke(request: encoded, cookie: cookie);
      if (ticket != _generation) {
        throw const FormatException('目录请求已取消。');
      }
      return result;
    } finally {
      await _release(id);
    }
  }
}

// Large catalogs cross FFI as JSON. Keep their serialization off the UI isolate.
Future<Map<String, dynamic>> decodeCatalogResponse(String text) async =>
    text.length < 65536
    ? _decodeCatalogJson(text)
    : compute(_decodeCatalogJson, text);

Map<String, dynamic> _decodeCatalogJson(String text) =>
    (jsonDecode(text) as Map).cast<String, dynamic>();

Future<String> encodeCatalogRequest(Map<String, dynamic> payload) async =>
    payload.containsKey('catalog_snapshot') ||
        (payload['input'] is String &&
            (payload['input'] as String).length >= 65536)
    ? compute(jsonEncode, payload)
    : jsonEncode(payload);
