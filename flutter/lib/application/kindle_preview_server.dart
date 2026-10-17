// 真机预览组件的本机连接（V30，LAY-108/110）。组件是 plugins/kindle-preview/ 里的网页，
// 由系统 Edge 以应用窗口打开；它通过这里读取本书、按还没写回的排版值生成内容、取阅读器参数、
// 写回本书。只听 127.0.0.1，所有路径以随机口令开头，并校验 Host，其他网页无法访问。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'layout_service.dart';

typedef KindlePreviewRender = Future<LayoutDraftPreview> Function(
  Map<String, Object?> values,
  String? entryId,
);

class KindlePreviewServer {
  KindlePreviewServer({
    required this.pluginDirectory,
    required this.state,
    required this.render,
    required this.metrics,
    required this.apply,
  });

  /// 组件目录（含 plugin.json、index.html）。
  final String pluginDirectory;

  /// 书名、机型、阅读器设置与当前排版值。
  final Map<String, Object?> Function() state;
  final KindlePreviewRender render;

  /// 阅读器字号、行高与页边距（与排版页小预览同一套参数）。
  final Map<String, Object?> Function(Map<String, Object?> request) metrics;

  /// 写回本书；返回 null 表示成功，否则为给用户看的原因。
  final Future<String?> Function(Map<String, Object?> values) apply;

  static const _maxBody = 256 * 1024;
  static const _keepRenders = 4;
  HttpServer? _server;
  final String token = _token();
  final _renders = <String, String>{};
  var _next = 0;

  static String _token() {
    final random = math.Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  bool get running => _server != null;

  /// 组件首页地址（含口令）。
  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}/$token/');

  Future<Uri> start() async {
    if (_server == null) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen((request) => unawaited(_handle(request)));
    }
    return url;
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    try {
      final port = _server?.port;
      final segments = request.uri.pathSegments;
      if (port == null ||
          request.headers.value('host') != '127.0.0.1:$port' ||
          segments.isEmpty ||
          segments.first != token) {
        return await _status(response, HttpStatus.forbidden);
      }
      final rest = segments.sublist(1);
      if (rest.length == 2 && rest.first == 'api') {
        if (request.method != 'POST' && rest[1] != 'state') {
          return await _status(response, HttpStatus.methodNotAllowed);
        }
        return await _api(request, rest[1]);
      }
      if (request.method != 'GET') {
        return await _status(response, HttpStatus.methodNotAllowed);
      }
      if (rest.length >= 3 && rest.first == 'book') {
        final root = _renders[rest[1]];
        if (root == null) return await _status(response, HttpStatus.notFound);
        return await _file(response, root, rest.sublist(2));
      }
      return await _file(
        response,
        pluginDirectory,
        rest.isEmpty || rest.every((s) => s.isEmpty) ? ['index.html'] : rest,
      );
    } catch (_) {
      try {
        _status(response, HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  Future<void> _api(HttpRequest request, String name) async {
    final response = request.response;
    Map<String, Object?> body = const {};
    if (request.method == 'POST') {
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBody) {
          return await _status(response, HttpStatus.requestEntityTooLarge);
        }
      }
      final decoded = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        return await _status(response, HttpStatus.badRequest);
      }
      body = decoded.cast<String, Object?>();
    }
    Map<String, Object?> values() =>
        ((body['values'] as Map?) ?? const {}).cast<String, Object?>();
    switch (name) {
      case 'state':
        return await _json(response, state());
      case 'metrics':
        return await _json(response, metrics(body));
      case 'render':
        try {
          final preview = await render(values(), body['entry'] as String?);
          final id = '${_next++}';
          _renders[id] = preview.directory;
          while (_renders.length > _keepRenders) {
            _renders.remove(_renders.keys.first);
          }
          return await _json(response, {
            'ok': true,
            'base': 'book/$id/',
            'content': preview.content,
            'anchor': preview.anchor,
            'title': preview.title,
          });
        } on FormatException catch (error) {
          return await _json(response, {'ok': false, 'message': error.message});
        } catch (_) {
          return await _json(response, {
            'ok': false,
            'message': '预览没有生成，请检查排版数值与本书资源。',
          });
        }
      case 'apply':
        final reason = await apply(values());
        return await _json(response, {
          'ok': reason == null,
          'message': ?reason,
        });
      default:
        return await _status(response, HttpStatus.notFound);
    }
  }

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'xhtml': 'application/xhtml+xml; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'svg': 'image/svg+xml',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ncx': 'application/xml; charset=utf-8',
    'opf': 'application/xml; charset=utf-8',
  };

  Future<void> _file(
    HttpResponse response,
    String root,
    List<String> segments,
  ) async {
    // 只接受普通文件名：不含 .、..、空段、反斜杠或盘符。
    if (segments.any(
      (s) => s.isEmpty || s == '.' || s == '..' || s.contains(RegExp(r'[\\:]')),
    )) {
      return await _status(response, HttpStatus.forbidden);
    }
    final base = Directory(root).absolute;
    final file = File([base.path, ...segments].join(Platform.pathSeparator));
    if (!await file.exists()) {
      return await _status(response, HttpStatus.notFound);
    }
    final resolved = await file.resolveSymbolicLinks();
    final baseResolved = await base.resolveSymbolicLinks();
    final prefix = baseResolved.endsWith(Platform.pathSeparator)
        ? baseResolved
        : '$baseResolved${Platform.pathSeparator}';
    if (!resolved.toLowerCase().startsWith(prefix.toLowerCase())) {
      return await _status(response, HttpStatus.forbidden);
    }
    final extension = segments.last.contains('.')
        ? segments.last.split('.').last.toLowerCase()
        : '';
    final type = _types[extension];
    if (type == null) return await _status(response, HttpStatus.forbidden);
    response.headers.set('Content-Type', type);
    await response.addStream(File(resolved).openRead());
    await response.close();
  }

  Future<void> _json(HttpResponse response, Object value) async {
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
    response.add(utf8.encode(jsonEncode(value)));
    await response.close();
  }

  Future<void> _status(HttpResponse response, int code) async {
    response.statusCode = code;
    await response.close();
  }
}
