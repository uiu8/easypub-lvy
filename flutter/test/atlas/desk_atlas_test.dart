// 全页面图集（R0，正式版打磨）：真实字体、测试假数据，按窗口宽度 × 主题 × 字号给每个页面出图，
// 另出书源插件五个页签，最后写一个 index.html 便于逐页翻看。
// 只在设置 DESK_ATLAS_OUT=<目录> 时运行（tools/run_desk_atlas.ps1），全量回归里跳过。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/fonts.dart';
import 'package:easypub_desktop/desk/grain.dart';
import 'package:easypub_desktop/desk/plugins/booksource_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../completion/desk_v88_booksource_test.dart' as v88;

class _NoPicker extends Fake implements BookFilePicker {}

final _out = Platform.environment['DESK_ATLAS_OUT'];

/// 窗口尺寸、主题、字号的组合；SIZES / THEMES / SCALES 环境变量可缩小范围（逗号分隔）。
List<String> _pick(String name, List<String> all) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) return all;
  return value.split(',').map((s) => s.trim()).where(all.contains).toList();
}

const _sizes = {
  '1100': Size(1100, 720),
  '1500': Size(1500, 900),
  '1900': Size(1900, 1060),
};
const _themes = ['paper', 'night', 'silver'];
const _scales = {'1.0': 1.0, '1.3': 1.3};

/// 样书：两卷、40 章，含一处跳号、一处重复标题与一个疑似标题的正文行，检查页有内容可看；
/// 另有行尾空白、连续空行和广告行（R4），清理页有差异与提示候选可看。
String _sampleBook() {
  final b = StringBuffer('山海之间\n作者：样例\n\n');
  for (var c = 1; c <= 40; c++) {
    if (c == 1) b.writeln('第一卷 远行');
    if (c == 21) b.writeln('第二卷 归来');
    if (c == 13) continue; // 跳号
    final title = c == 30 ? '第三十章 风起' : '第$c章 ${c.isEven ? '风起' : '云涌'}$c';
    b.writeln(title);
    for (var p = 0; p < 6; p++) {
      b.writeln('　　这是第$c章的第${p + 1}段正文，山路很长，海风很轻，行人一步一步走向远方。');
    }
    if (c == 8) b.writeln('第八章我杀这边的人，他们都看着我');
    if (c % 6 == 0) b.writeln('　　这一行的末尾留着几个空格。   ');
    if (c % 9 == 0) b.write('\n\n\n');
    if (c == 15 || c == 27) {
      b.writeln('本章未完，请点击下一页继续阅读');
      b.writeln('最新章节请访问 www.example-novel.invalid 手机版阅读');
    }
    b.writeln();
  }
  return b.toString();
}

Future<void> _loadFonts() async {
  await loadDeskFonts();
  final fonts = '${Platform.environment['WINDIR'] ?? r'C:\Windows'}\\Fonts';
  // 界面字体缺字时的回退（与真实窗口相同的 deskFallback），否则 ▾ 等符号会显示成方框。
  for (final (family, file) in [
    ('Microsoft YaHei', 'msyh.ttc'),
    ('Segoe UI', 'segoeui.ttf'),
    ('Segoe UI Symbol', 'seguisym.ttf'),
  ]) {
    final f = File('$fonts\\$file');
    if (!f.existsSync()) continue;
    final bytes = await f.readAsBytes();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
  await (FontLoader('MaterialIcons')..addFont(
        File(
          '${Platform.environment['FLUTTER_ROOT'] ?? 'D:/software/EasyPub-Toolchains/flutter-3.47.3'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((b) => b.buffer.asByteData()),
      ))
      .load();
}

void main() {
  final entries = <Map<String, String>>[];

  Future<void> shot(
    WidgetTester t,
    GlobalKey key,
    String page,
    String label,
    String combo,
  ) async {
    final name = '${page.replaceAll(RegExp(r'[^a-z0-9-]'), '_')}__$combo.png';
    await t.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$_out/$name').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    entries.add({'page': page, 'label': label, 'combo': combo, 'file': name});
  }

  Future<void> settle(WidgetTester t, {int max = 150}) async {
    for (var i = 0; i < max; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 20));
      if (i > 15 &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
  }

  testWidgets('应用页面图集', skip: _out == null, timeout: Timeout.none, (t) async {
    debugDisableShadows = false;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    late LegacyLibraryAdapter library;
    late String bookId;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      await _loadFonts();
      await prepareDeskGrain();
      await Directory(_out!).create(recursive: true);
      final tmp = await Directory.systemTemp.createTemp('desk-atlas-');
      final state = PrototypeState(settingsDirectory: '${tmp.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      final main = File('${tmp.path}/山海之间.txt');
      await main.writeAsString(_sampleBook());
      final files = [main.path];
      for (final name in [
        '神通者',
        '龙游令',
        '祖传风水师笔记',
        '原来我是仙道天骄',
        '福尔摩斯小姐今天也怀疑我是凶手',
        '神宠供应商',
        '电诈风云',
      ]) {
        final f = File('${tmp.path}/$name.txt');
        await f.writeAsString('第一章 开端\n正文。\n\n第二章 继续\n正文。\n');
        files.add(f.path);
      }
      await library.importFiles(files);
      bookId = library.books.value.firstWhere((b) => b.title == '山海之间').id;
      // R5：给样书一张插图（第 1 章第 2 段之后，原稿第 7 行），资源页和排版预览才有内容。图在测试里画，不用外部文件。
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 480, 320),
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, const Offset(480, 320), [
            const Color(0xff5E6D7D),
            const Color(0xffC9B99A),
          ]),
      );
      final image = await recorder.endRecording().toImage(480, 320);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final plate = File('${tmp.path}/山海图.png')
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
      final resources = library.openResources(bookId);
      try {
        await resources.apply(
          await resources.change(index: null, path: plate.path, sourceLine: 7),
        );
      } finally {
        resources.dispose();
      }
    });
    library.createCollection('武侠');
    library.createCollection('待读');
    library.selectBook(bookId);
    final book = Uri.encodeComponent(bookId);
    final pages = <(String, String, String)>[
      ('library', '书库', '/'),
      ('folders', '文件夹与收藏', '/folders'),
      ('mapping', '元数据映射', '/folders/mapping'),
      ('overview', '书稿概览', '/books/$book/overview'),
      ('chapters', '章节', '/books/$book/chapters'),
      ('checks', '检查与修复', '/books/$book/checks'),
      ('rules', '识别与检查规则', '/books/$book/rules'),
      ('repairs', '章节修复', '/books/$book/repairs'),
      ('catalog', '参考目录', '/books/$book/catalog'),
      ('cleanup', '文本清理', '/books/$book/cleanup'),
      ('information', '书籍信息', '/books/$book/information'),
      ('layout', '排版', '/books/$book/layout'),
      ('resources', '图片与资源', '/books/$book/resources'),
      ('conversion', '转换', '/conversion'),
      ('tasks', '任务', '/tasks'),
      ('task-history', '转换历史', '/tasks/history'),
      ('history', '记录', '/history'),
      ('plugins', '插件', '/plugins'),
      ('settings', '设置', '/settings'),
    ];
    final key = GlobalKey();
    for (final theme in _pick('THEMES', _themes)) {
      for (final scale in _pick('SCALES', _scales.keys.toList())) {
        await t.runAsync(
          () => library.savePatch({
            'ui_theme': theme,
            'ui_scale': _scales[scale],
            'ui_follow_system_scale': false,
          }),
        );
        for (final size in _pick('SIZES', _sizes.keys.toList())) {
          t.view.physicalSize = _sizes[size]!;
          t.view.devicePixelRatio = 1;
          await t.pumpWidget(
            RepaintBoundary(
              key: key,
              child: RewriteApp(
                key: ValueKey('$theme $scale $size'),
                library: library,
                picker: _NoPicker(),
              ),
            ),
          );
          await settle(t);
          final router = GoRouter.of(
            t.element(find.byKey(const ValueKey('workspace-output-bar'))),
          );
          for (final (id, label, route) in pages) {
            router.go(route);
            await settle(t);
            await shot(t, key, id, label, '$size-$theme-$scale');
            // 页面异常只记录，不中断出图。
            final error = t.takeException();
            if (error != null) {
              entries.last['error'] = '$error'.split('\n').first;
            }
          }
          // R4：清理页的“逐步骤差异”“提示候选”“清理差异（待确认）”三种状态。
          Future<void> tapText(String text) async {
            await t.tap(find.text(text).first);
            await settle(t);
          }

          Future<void> cleanupShot(
            String id,
            String label,
            Future<void> Function() open,
          ) async {
            try {
              await open();
              await shot(t, key, id, label, '$size-$theme-$scale');
            } catch (e) {
              entries.add({
                'page': id,
                'label': label,
                'combo': '$size-$theme-$scale',
                'file': '',
                'error': '$e'.split('\n').first,
              });
            }
            t.takeException();
          }

          router.go('/books/$book/cleanup');
          await settle(t);
          await cleanupShot(
            'cleanup-stages',
            '文本清理 · 逐步骤差异',
            () => tapText('逐步骤差异'),
          );
          await tapText('最终差异');
          await cleanupShot(
            'cleanup-candidates',
            '文本清理 · 提示候选',
            () => t
                .tap(find.textContaining('审阅提示候选').first)
                .then((_) => settle(t)),
          );
          await tapText('查看变更');
          await cleanupShot(
            'cleanup-diff',
            '文本清理 · 清理差异（待确认）',
            () => tapText('查看清理差异…'),
          );
          final back = find.text('返回调整');
          if (back.evaluate().isNotEmpty) await tapText('返回调整');
          // 导航栏展开（G-084）：宽窗时栏底有“展开导航栏”，展开后出一张书库图再收回。
          final toggle = find.byKey(const ValueKey('desk-rail-toggle'));
          if (toggle.evaluate().isNotEmpty) {
            router.go('/');
            await settle(t);
            await t.tap(toggle);
            await settle(t);
            await shot(
              t,
              key,
              'shell-rail-expanded',
              '外壳 · 导航栏展开',
              '$size-$theme-$scale',
            );
            await t.tap(toggle);
            await settle(t);
          }
          // 外壳弹窗与菜单（R1）：只出两个组合，打开后截图，再按 Esc 关掉。
          final combo = '$size-$theme-$scale';
          if (combo == '1500-paper-1.0' || combo == '1100-night-1.3') {
            router.go('/books/$book/chapters');
            await settle(t);
            Future<void> overlay(
              String id,
              String label,
              Future<void> Function() open,
            ) async {
              try {
                await open();
                await t.pump();
                await t.pump(const Duration(milliseconds: 400));
                // 弹窗加载中（转圈）时等它加载完，否则 Esc 关不掉、会挡住下一个。
                await settle(t, max: 60);
                await shot(t, key, id, label, combo);
              } catch (e) {
                entries.add({
                  'page': id,
                  'label': label,
                  'combo': combo,
                  'file': '',
                  'error': '$e'.split('\n').first,
                });
              }
              await t.sendKeyEvent(LogicalKeyboardKey.escape);
              await settle(t, max: 30);
              t.takeException();
            }

            await overlay(
              'shell-book-picker',
              '外壳 · 选书弹窗',
              () => t.tap(
                find.byKey(const ValueKey('workspace-book-picker')).first,
              ),
            );
            await overlay('shell-command', '外壳 · 命令面板', () async {
              await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
              await t.sendKeyEvent(LogicalKeyboardKey.keyK);
              await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            });
            await overlay(
              'shell-project',
              '外壳 · 项目菜单',
              () => t.tap(find.text('项目').first),
            );
            await overlay(
              'shell-page-menu',
              '外壳 · 页面导航菜单',
              () => t.tap(find.byTooltip('页面导航').first),
            );
            await overlay(
              'shell-quick-layout',
              '外壳 · 快速排版',
              // 窄窗时提示后面还接着当前预设名（R1），按开头匹配。
              () => t.tap(
                find
                    .byWidgetPredicate(
                      (w) =>
                          w is Tooltip &&
                          (w.message ?? '').startsWith('本次书稿排版预设'),
                    )
                    .first,
              ),
            );
            await overlay(
              'shell-quick-actions',
              '外壳 · 快捷操作菜单',
              () => t.tap(find.byTooltip('快捷操作').first),
            );
            await overlay(
              'shell-save',
              '外壳 · 保存状态',
              () => t.tap(find.byKey(const ValueKey('desk-save-badge')).first),
            );
            // R5：排版页的三个弹窗、窄窗时的阅读预览，书籍信息的文字封面。
            router.go('/books/$book/layout');
            await settle(t);
            for (final (id, label, text) in [
              ('layout-presets', '排版 · 预设库', '预设库 / 另存为预设'),
              ('layout-origins', '排版 · 设置来源', '设置来源 / 恢复默认'),
              ('layout-batch', '排版 · 应用到多本书', '应用到多本书'),
            ]) {
              await overlay(id, label, () => t.tap(find.text(text).first));
              // 这几个弹窗是 Material Dialog，Esc 不一定关得掉；还开着就直接退回。
              final open = find.byType(Dialog);
              if (open.evaluate().isNotEmpty) {
                Navigator.of(t.element(open.first)).pop();
                await settle(t, max: 30);
              }
            }
            // 第 1 章的插图排在小预览第 2 页（R5-01）。
            final next = find.text('下一页');
            if (next.evaluate().isNotEmpty) {
              await t.tap(next.first);
              await settle(t);
              await shot(t, key, 'layout-page2', '排版 · 预览第 2 页（插图）', combo);
              await t.tap(find.text('上一页').first);
              await settle(t);
            }
            if (find.text('阅读预览').evaluate().isNotEmpty) {
              await overlay(
                'layout-preview-pane',
                '排版 · 阅读预览（切换）',
                () => t.tap(find.text('阅读预览').first),
              );
            }
            router.go('/books/$book/information');
            await settle(t);
            await overlay('cover-text', '书籍信息 · 生成文字封面', () async {
              // 窄窗大字号时按钮在封面栏下方，先滚进视野。
              await t.ensureVisible(find.text('生成文字封面').first);
              await settle(t);
              await t.tap(find.text('生成文字封面').first);
            });
            router.go('/books/$book/chapters');
            await settle(t);
          }
        }
      }
    }
    // R4：最后一个组合里真的采用一次清理，拍“采用结果”和有记录的变更记录页（采用会改样书，所以只做一次）。
    final last =
        '${_pick('SIZES', _sizes.keys.toList()).last}-${_pick('THEMES', _themes).last}-${_pick('SCALES', _scales.keys.toList()).last}';
    try {
      final router = GoRouter.of(
        t.element(find.byKey(const ValueKey('workspace-output-bar'))),
      );
      router.go('/books/$book/cleanup');
      await settle(t);
      await t.tap(find.text('查看清理差异…').first);
      await settle(t);
      await t.tap(find.byKey(const Key('cleanup-apply')));
      await settle(t);
      // 有章节修改要放弃时会弹确认；样书没有章节修改，正常不会出现。
      final confirm = find.text('确认放弃并采用');
      if (confirm.evaluate().isNotEmpty) {
        await t.tap(confirm.first);
        await settle(t);
      }
      await shot(t, key, 'cleanup-result', '文本清理 · 采用结果', last);
      router.go('/history');
      await settle(t);
      await shot(t, key, 'history-filled', '记录 · 有记录', last);
    } catch (e) {
      entries.add({
        'page': 'cleanup-result',
        'label': '文本清理 · 采用结果',
        'combo': last,
        'file': '',
        'error': '$e'.split('\n').first,
      });
    }
    t.takeException();
    await t.pumpWidget(const SizedBox.shrink());
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    debugDisableShadows = true;
  });

  testWidgets('书源插件页签图集', skip: _out == null, timeout: Timeout.none, (t) async {
    debugDisableShadows = false;
    await t.runAsync(_loadFonts);
    final temp = Directory.systemTemp.createTempSync('desk-atlas-bs-');
    final key = GlobalKey();
    for (final theme in _pick('THEMES', _themes)) {
      for (final scale in _pick('SCALES', _scales.keys.toList())) {
        final api = v88.V88Api();
        // 补些假书源，接近真实书源页的密度（各种状态都有）。
        for (var i = 0; i < 40; i++) {
          api.sourceList.add({
            'id': 'https://fake-$i.invalid',
            'name': '样例书源 $i',
            'group': i.isEven ? '小说' : '精品',
            'file': i < 20 ? '旧版导入' : 'https://example.invalid/s.json',
            'enabled': i % 7 != 0,
            'supported': i % 11 != 0,
            'reasons': i % 11 == 0 ? ['脚本用了尚未支持的函数'] : [],
            'webView': i % 5 == 0,
            if (i % 3 == 0) 'check': {'ok': i % 2 == 0, 'ms': 300 + i * 40},
          });
        }
        t.view.physicalSize = const Size(1500, 900);
        t.view.devicePixelRatio = 1;
        await t.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              key: ValueKey('$theme $scale'),
              theme: deskTheme(mode: theme),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(_scales[scale]!)),
                child: child!,
              ),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: BookSourcePage(
                    openApi: () async => api,
                    settingsPath: '${temp.path}/ui-$theme-$scale.json',
                    chooseFolder: () async => temp.path,
                    chooseSourceFile: () async => null,
                    importToLibrary: (_) async => null,
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
        for (final (id, label, tab) in [
          ('bs-search', '书源 · 搜索', '搜索'),
          ('bs-shelf', '书源 · 书架', '书架'),
          ('bs-sources', '书源 · 书源', '书源'),
          ('bs-downloads', '书源 · 下载', '下载'),
          ('bs-settings', '书源 · 设置', '设置'),
        ]) {
          await t.tap(
            find
                .descendant(
                  of: find.byKey(const ValueKey('booksource-tabs')),
                  matching: find.textContaining(tab),
                )
                .first,
          );
          await t.pump(const Duration(milliseconds: 400));
          await shot(t, key, id, label, '1500-$theme-$scale');
        }
        await t.pumpWidget(const SizedBox.shrink());
        await api.events_.close();
      }
    }
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    debugDisableShadows = true;
  });

  tearDownAll(() async {
    if (_out == null || entries.isEmpty) return;
    await File('$_out/atlas.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(entries));
    final pages = <String, List<Map<String, String>>>{};
    for (final e in entries) {
      (pages[e['page']!] ??= []).add(e);
    }
    String esc(String s) => const HtmlEscape().convert(s);
    final html = StringBuffer('''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>页面图集</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{font-family:"Microsoft YaHei",sans-serif;margin:16px;background:#f4f1ec;color:#2b2825}
nav a{margin-right:10px;white-space:nowrap}
section{margin:28px 0}h2{margin:0 0 8px}
.grid{display:flex;flex-wrap:wrap;gap:12px}
figure{margin:0;background:#fff;border:1px solid #ddd6cc;border-radius:8px;padding:6px}
figure img{width:360px;display:block;border-radius:4px}
figcaption{font-size:12px;color:#6b655d;margin-top:4px}
.err{color:#a33}
</style></head><body><h1>页面图集</h1><p>真实字体、测试假数据。点缩略图看原图。</p><nav>''');
    for (final e in pages.entries) {
      html.write('<a href="#${e.key}">${esc(e.value.first['label']!)}</a>');
    }
    html.write('</nav>');
    for (final e in pages.entries) {
      html.write(
        '<section id="${e.key}"><h2>${esc(e.value.first['label']!)}</h2><div class="grid">',
      );
      for (final s in e.value) {
        html.write(
          '<figure>${s['file']!.isEmpty ? '' : '<a href="${s['file']}"><img loading="lazy" src="${s['file']}"></a>'}'
          '<figcaption>${esc(s['combo']!)}'
          '${s['error'] == null ? '' : '<br><span class="err">${esc(s['error']!)}</span>'}'
          '</figcaption></figure>',
        );
      }
      html.write('</div></section>');
    }
    html.write('</body></html>');
    await File('$_out/index.html').writeAsString(html.toString());
  });
}
