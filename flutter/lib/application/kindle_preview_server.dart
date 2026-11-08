// 真机预览组件的本机连接（V30，LAY-108/110）。组件是 plugins/kindle-preview/ 里的网页，
// 由系统 Edge 以应用窗口打开；它通过这里读取本书、按还没写回的排版值生成内容、取阅读器参数、
// 写回本书。只听 127.0.0.1，所有路径以随机口令开头，并校验 Host，其他网页无法访问。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'layout_service.dart';

/// 认出 Kindle 自带的中文字体（V128，LAY-183）：按字体内部的字族名，不看文件名。
/// 返回 {face: song|hei|kai|yuan, script: sc|tc, bold}；不是这几种时返回 null。
/// 名字来自 KPW5 固件 5.17.1.0.3 与 5.19.2 的字体：简体宋体内部名是“STBShusong”
/// （粗体“STBShusong-Bold”，字重字段仍写 400），简体圆体常规体是“STZhongyuan”。
Map<String, Object>? kindleFontOf(List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  var base = 0;
  if (String.fromCharCodes(bytes.sublist(0, 4)) == 'ttcf') {
    if (bytes.length < 16) return null;
    base = view.getUint32(12);
  }
  if (base + 12 > bytes.length) return null;
  final count = view.getUint16(base + 4);
  final tables = <String, (int, int)>{};
  for (var i = 0; i < count; i++) {
    final at = base + 12 + i * 16;
    if (at + 16 > bytes.length) return null;
    tables[String.fromCharCodes(bytes.sublist(at, at + 4))] = (
      view.getUint32(at + 8),
      view.getUint32(at + 12),
    );
  }
  final name = tables['name'];
  if (name == null || name.$1 + 6 > bytes.length) return null;
  final names = <int, String>{};
  final records = view.getUint16(name.$1 + 2);
  final strings = name.$1 + view.getUint16(name.$1 + 4);
  for (var i = 0; i < records; i++) {
    final at = name.$1 + 6 + i * 12;
    if (at + 12 > bytes.length) break;
    final platform = view.getUint16(at);
    final id = view.getUint16(at + 6);
    final length = view.getUint16(at + 8);
    final start = strings + view.getUint16(at + 10);
    if (start + length > bytes.length || names.containsKey(id)) continue;
    if (platform == 3) {
      names[id] = String.fromCharCodes([
        for (var j = 0; j + 1 < length; j += 2) view.getUint16(start + j),
      ]);
    } else if (platform == 1) {
      names[id] = String.fromCharCodes(bytes.sublist(start, start + length));
    }
  }
  final family = (names[16] ?? names[1] ?? '')
      .replaceAll(
        RegExp(r'[- ]?(Bold|Medium|Regular)$', caseSensitive: false),
        '',
      )
      .toLowerCase();
  final face = switch (family) {
    'stbshusong' || 'stsong' || 'stsongti' || 'stsongtc' => 'song',
    'stheiti' || 'stheititc' => 'hei',
    'stkai' || 'stkaiti' || 'stkaititc' => 'kai',
    'styuan' || 'stzhongyuan' || 'styuantc' => 'yuan',
    _ => null,
  };
  if (face == null) return null;
  final os2 = tables['OS/2'];
  final weight = os2 != null && os2.$1 + 6 <= bytes.length
      ? view.getUint16(os2.$1 + 4)
      : 400;
  final style =
      '${names[17] ?? ''} ${names[2] ?? ''} ${names[4] ?? ''} ${names[1] ?? ''}';
  return {
    'face': face,
    'script': family.endsWith('tc') ? 'tc' : 'sc',
    'bold':
        weight >= 600 || RegExp(r'bold', caseSensitive: false).hasMatch(style),
  };
}

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
    this.fontDirectory,
  });

  /// 导入的预览字体放在这里（V123，LAY-178）：fonts.json 记名字与上次选的阅读器字体。
  /// 只给预览用，不进书里；为 null 时不能导入。
  final String? fontDirectory;

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
  static const _maxFont = 64 * 1024 * 1024;
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
      if (rest.length == 2 && rest.first == 'api' && rest[1] == 'font-import') {
        if (request.method != 'POST') {
          return await _status(response, HttpStatus.methodNotAllowed);
        }
        return await _importFont(request);
      }
      if (rest.length == 2 && rest.first == 'api') {
        if (request.method != 'POST' && rest[1] != 'state') {
          return await _status(response, HttpStatus.methodNotAllowed);
        }
        return await _api(request, rest[1]);
      }
      if (request.method != 'GET') {
        return await _status(response, HttpStatus.methodNotAllowed);
      }
      final fonts = fontDirectory;
      if (rest.length == 2 && rest.first == 'fonts' && fonts != null) {
        return await _file(response, fonts, [rest[1]]);
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
        final index = _fontIndex();
        return await _json(response, {
          ...state(),
          'fonts': index['fonts'],
          'reader_font': index['selected'],
        });
      case 'font-select':
        final index = _fontIndex();
        final font = body['font'];
        if (fontDirectory != null && font is String && font.length < 80) {
          _saveFontIndex({...index, 'selected': font});
        }
        return await _json(response, {'ok': true});
      case 'font-remove':
        final index = _fontIndex();
        final fonts = [...index['fonts'] as List];
        final gone = fonts
            .where((f) => (f as Map)['id'] == body['id'])
            .toList();
        for (final f in gone) {
          fonts.remove(f);
          try {
            File('$fontDirectory${Platform.pathSeparator}${(f as Map)['file']}')
                .deleteSync();
          } on FileSystemException {
            // 文件已不在时只更新清单。
          }
        }
        if (gone.isNotEmpty) _saveFontIndex({...index, 'fonts': fonts});
        return await _json(response, {'ok': true, 'fonts': fonts});
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

  /// 导入一个预览字体：请求体是字体文件本身，X-Font-Name 是文件名（URI 编码）。
  Future<void> _importFont(HttpRequest request) async {
    final response = request.response;
    final dir = fontDirectory;
    if (dir == null) {
      return await _json(response, {'ok': false, 'message': '这里不能导入字体。'});
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > _maxFont) {
        return await _json(response, {
          'ok': false,
          'message': '字体文件超过 64 MB，不能导入。',
        });
      }
    }
    final data = bytes.takeBytes();
    final head = data.length < 4
        ? ''
        : String.fromCharCodes(data.sublist(0, 4));
    final extension = switch (head) {
      'OTTO' => 'otf',
      'true' || '\x00\x01\x00\x00' => 'ttf',
      'ttcf' => 'ttc',
      'wOFF' => 'woff',
      'wOF2' => 'woff2',
      _ => null,
    };
    if (extension == null) {
      return await _json(response, {
        'ok': false,
        'message': '这不是字体文件，请选 TTF / OTF / TTC / WOFF 字体。',
      });
    }
    var name = '';
    try {
      name = Uri.decodeComponent(request.headers.value('x-font-name') ?? '');
    } on ArgumentError {
      name = '';
    }
    name = name.replaceAll(
      RegExp(r'\.(ttf|otf|ttc|woff2?)$', caseSensitive: false),
      '',
    );
    name = name.replaceAll(RegExp(r'[\x00-\x1f<>"]'), '').trim();
    if (name.length > 60) name = name.substring(0, 60);
    if (name.isEmpty) name = '导入的字体';
    final id = sha256.convert(data).toString().substring(0, 16);
    final file = '$id.$extension';
    final kindle = kindleFontOf(data);
    Directory(dir).createSync(recursive: true);
    File('$dir${Platform.pathSeparator}$file').writeAsBytesSync(data);
    final index = _fontIndex();
    // 同一种 Kindle 字体（字体、简繁、粗细都相同）只留最新导入的一份（V128）。
    bool same(Map f) {
      final k = f['kindle'];
      return kindle != null &&
          k is Map &&
          k['face'] == kindle['face'] &&
          k['script'] == kindle['script'] &&
          k['bold'] == kindle['bold'];
    }

    final fonts = <Object?>[];
    for (final f in index['fonts'] as List) {
      final m = f as Map;
      if (m['id'] == id) continue;
      if (same(m)) {
        try {
          File('$dir${Platform.pathSeparator}${m['file']}').deleteSync();
        } on FileSystemException {
          // 文件已不在时只更新清单。
        }
        continue;
      }
      fonts.add(f);
    }
    fonts.add({
      'id': id,
      'name': name,
      'file': file,
      if (kindle != null) 'kindle': kindle else 'plain': true,
    });
    _saveFontIndex({...index, 'fonts': fonts});
    return await _json(response, {
      'ok': true,
      'font': fonts.last,
      'fonts': fonts,
    });
  }

  /// 字体清单；读不了或格式不对时当作空的。只列出文件还在的字体。
  Map<String, Object?> _fontIndex() {
    final dir = fontDirectory;
    if (dir == null) return {'fonts': const [], 'selected': null};
    try {
      final value = jsonDecode(
        File('$dir${Platform.pathSeparator}fonts.json').readAsStringSync(),
      );
      if (value is Map) {
        final fonts = [
          for (final f in (value['fonts'] as List? ?? const []))
            if (f is Map &&
                f['id'] is String &&
                f['name'] is String &&
                f['file'] is String &&
                RegExp(r'^[0-9a-f]{16}\.(ttf|otf|ttc|woff2?)$')
                    .hasMatch(f['file'] as String) &&
                File('$dir${Platform.pathSeparator}${f['file']}').existsSync())
              {
                'id': f['id'],
                'name': f['name'],
                'file': f['file'],
                if (f['kindle'] case {
                  'face': 'song' || 'hei' || 'kai' || 'yuan',
                  'script': 'sc' || 'tc',
                  'bold': bool _,
                })
                  'kindle': {
                    'face': f['kindle']['face'],
                    'script': f['kindle']['script'],
                    'bold': f['kindle']['bold'],
                  }
                else if (f['plain'] == true)
                  'plain': true,
              },
        ];
        var selected = value['selected'] is String
            ? value['selected'] as String
            : null;
        // V128 以前导入的字体还没认过：读一次字体文件，认出 Kindle 字体后记进清单。
        // 同一种 Kindle 字体有几份时，最后导入的那份对应到宋体等选项，较早的按普通导入字体列出。
        final unchecked = fonts
            .where((f) => f['kindle'] == null && f['plain'] == null)
            .toList();
        if (unchecked.isNotEmpty) {
          for (final f in unchecked) {
            Map<String, Object>? kind;
            try {
              kind = kindleFontOf(
                File('$dir${Platform.pathSeparator}${f['file']}')
                    .readAsBytesSync(),
              );
            } on FileSystemException {
              kind = null;
            }
            if (kind == null) {
              f['plain'] = true;
            } else {
              f['kindle'] = kind;
            }
          }
          // 上次选的若是认出的 Kindle 常规体（包括较早的那份），改选对应的宋体等选项。
          for (final f in fonts) {
            final k = f['kindle'] as Map?;
            if (k != null &&
                k['bold'] == false &&
                selected == 'user:${f['id']}') {
              selected = k['face'] as String;
            }
          }
          final seen = <String>{};
          for (final f in fonts.reversed) {
            final k = f['kindle'] as Map?;
            if (k == null) continue;
            if (!seen.add('${k['face']}/${k['script']}/${k['bold']}')) {
              f.remove('kindle');
              f['plain'] = true;
            }
          }
          _saveFontIndex({'fonts': fonts, 'selected': selected});
        }
        return {'fonts': fonts, 'selected': selected};
      }
    } on Object {
      // 清单损坏时重新开始；字体文件本身不受影响。
    }
    return {'fonts': const [], 'selected': null};
  }

  void _saveFontIndex(Map<String, Object?> index) {
    final dir = fontDirectory;
    if (dir == null) return;
    Directory(dir).createSync(recursive: true);
    File('$dir${Platform.pathSeparator}fonts.json')
        .writeAsStringSync(jsonEncode(index));
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
    'ttc': 'font/collection',
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
