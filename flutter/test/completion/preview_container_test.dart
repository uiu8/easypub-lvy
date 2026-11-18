import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/kindle_preview_server.dart';
import 'package:easypub_desktop/application/layout_service.dart';

void main() {
  test('原书预览通过真实服务提供 EPUB 容器和章节清单', () async {
    final root = await Directory.systemTemp.createTemp('preview-container-');
    final meta = await Directory('${root.path}/META-INF').create();
    await File('${meta.path}/container.xml').writeAsString(
      '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
    );
    await File('${root.path}/book.opf').writeAsString(
      '<package><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
    );
    final server = KindlePreviewServer(
      pluginDirectory: root.path,
      state: () => {},
      render: (_, _) async => LayoutDraftPreview(
        directory: root.path,
        content: 'c1.xhtml',
        title: '样书',
        layoutSource: 'original',
      ),
      metrics: (_) => {},
      apply: (_) async => null,
    );
    final client = HttpClient();
    try {
      final base = await server.start();
      final request = await client.postUrl(base.resolve('api/render'));
      request.write('{}');
      final rendered = jsonDecode(
        await utf8.decoder.bind(await request.close()).join(),
      ) as Map;
      for (final file in ['META-INF/container.xml', 'book.opf']) {
        final response = await (await client.getUrl(
          base.resolve('${rendered['base']}$file'),
        )).close();
        expect(response.statusCode, 200, reason: file);
        expect(response.headers.contentType?.mimeType, 'application/xml');
        expect(
          await utf8.decoder.bind(response).join(),
          contains(file.endsWith('.xml') ? 'book.opf' : 'c2'),
        );
      }
    } finally {
      client.close(force: true);
      await server.close();
      await root.delete(recursive: true);
    }
  });
}
