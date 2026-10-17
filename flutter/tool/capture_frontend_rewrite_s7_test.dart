import 'package:easypub_desktop/application/folder_count_service.dart';

// Visual data only. No conversion or acceptance claim is made by this harness.
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/application/output_history_service.dart';
import 'package:easypub_desktop/application/change_history_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';

class VisualConversion extends Fake
    implements ConversionSession, ConversionTaskFeed {
  List<ConversionOutput> historical = [];
  @override
  Future<void> loadTaskFeed() async {}
  @override
  String get taskFeedStatus => '';
  @override
  List<ConversionOutput> get taskFeed => [...outputs, ...historical];
  @override
  final ChangeNotifier changes = ChangeNotifier();
  bool blocked = false;
  @override
  bool busy = false;
  @override
  ConversionRequest? request = ConversionRequest(
    books: ['river', 'sea'],
    directory: r'D:\Books\EasyPub 输出',
    format: 'MOBI',
    generateCover: true,
    engine: r'D:\portable\converters\kindling.exe',
  );
  @override
  List<ConversionOutput> outputs = [];
  @override
  bool isCurrent(ConversionPreview preview) => true;
  @override
  Future<ConversionPreview> preview(ConversionRequest value) async {
    request = value;
    return ConversionPreview(
      [
        for (final id in ['river', 'sea'])
          ConversionFinding(
            id,
            '源文件与编码',
            'pass',
            '原稿可读取，编码已确认。',
            null,
            category: 'source',
          ),
        ConversionFinding(
          'river',
          '章节编号跳跃',
          'warning',
          blocked
              ? '2 处待核对；处理阻止项后仍可审阅提醒。'
              : '第86章至第88章编号不连续；请核对原文，不能仅凭编号判断正文缺失。',
          'chapters',
          category: 'chapters',
        ),
        if (!blocked)
          const ConversionFinding(
            'river',
            '章节编号跳跃',
            'warning',
            '第120章至第122章编号不连续；请核对原文，不能仅凭编号判断正文缺失。',
            'chapters',
            category: 'chapters',
          ),
        for (final id in ['river', 'sea'])
          ConversionFinding(
            id,
            blocked && id == 'river' ? '封面文件不可访问' : '封面与插图',
            blocked && id == 'river' ? 'blocking' : 'pass',
            blocked && id == 'river' ? 'cover.jpg' : '封面与插图可读取。',
            blocked && id == 'river' ? 'metadata' : null,
            category: 'resources',
            isCoverIssue: blocked && id == 'river',
          ),
        for (final id in ['river', 'sea'])
          ConversionFinding(
            id,
            '书目信息',
            'pass',
            '书名、作者和语言完整。',
            null,
            category: 'metadata',
          ),
        const ConversionFinding(
          'river',
          '输出位置与同名文件',
          'pass',
          '两个成品均可写入，同名文件自动添加序号，不覆盖。',
          null,
          category: 'destination',
        ),
        const ConversionFinding(
          'river',
          '转换器与目标格式',
          'pass',
          'MOBI转换器可用。',
          null,
          category: 'converter',
        ),
      ],
      const [
        ConversionOutput(
          'river',
          '长河照影',
          r'D:\书稿\成品\长河照影.mobi',
          '待确认',
          format: 'MOBI',
        ),
        ConversionOutput(
          'sea',
          '山海来信',
          r'D:\书稿\成品\山海来信.mobi',
          '待确认',
          format: 'MOBI',
        ),
      ],
      previewed: !blocked,
    );
  }

  @override
  void dispose() => changes.dispose();
}

class VisualChanges extends Fake implements ChangeHistoryService {
  @override
  final ChangeNotifier changes = ChangeNotifier();
  final items = const [
    ChangeRecord(
      'move',
      'river',
      '章节',
      '移动章节',
      3,
      true,
      true,
      'chapters',
      category: '章节',
    ),
    ChangeRecord(
      'clean',
      'river',
      '文本清理',
      '清理空行',
      2,
      true,
      true,
      'cleanup',
      category: '文本清理',
    ),
    ChangeRecord(
      'meta',
      'river',
      '制作',
      '修改书籍信息',
      1,
      true,
      true,
      'information',
      category: '书籍信息',
    ),
  ];
  @override
  List<ChangeRecord> records(String bookId) =>
      items.where((r) => r.bookId == bookId).toList();
  @override
  Future<HistoryTrees> chapterTrees(
    ChangeDetail detail,
    int offset, {
    String? entryId,
  }) async => HistoryTrees(
    const [
      HistoryTreeNode('volume1', '第一卷', 0, 'volume'),
      HistoryTreeNode('chapter', '第十二章 夜渡', 1, 'chapter'),
      HistoryTreeNode('volume2', '第二卷', 0, 'volume'),
    ],
    const [
      HistoryTreeNode('volume1', '第一卷', 0, 'volume'),
      HistoryTreeNode('volume2', '第二卷', 0, 'volume'),
      HistoryTreeNode('chapter', '第十二章 夜渡', 1, 'chapter'),
    ],
    3,
    3,
    offset,
    entryId: entryId,
    beforeFound:
        entryId != null && ['volume1', 'volume2', 'chapter'].contains(entryId),
    afterFound:
        entryId != null && ['volume1', 'volume2', 'chapter'].contains(entryId),
  );
  @override
  ChangeDetail detail(ChangeRecord record) => ChangeDetail(record, const [
    ChangedField('章节位置', '第一卷 · 第十二章 夜渡', '第二卷 · 第十二章 夜渡'),
  ], 'visual-only');
}

class VisualOutput extends Fake implements OutputHistoryService {
  @override
  final ChangeNotifier changes = ChangeNotifier();
  @override
  String get status => '';
  final record = OutputRecord(
    id: 'output',
    title: '长河照影',
    format: 'AZW3',
    path: r'D:\书稿\成品\长河照影.azw3',
    directory: r'D:\书稿\成品',
    status: '已完成',
    detail: '转换完成',
    verification: '当前文件与导出回执一致',
    startedAt: DateTime(2026, 9, 30, 14, 32),
    restored: false,
    busy: false,
    terminal: true,
    interrupted: false,
    bytes: 2485120,
    sourcePreserved: true,
    verificationCode: 'matches',
  );
  @override
  int get count => 1;
  @override
  OutputRecord? find(String id) => record;
  @override
  List<OutputRecord> page(int offset, {int limit = 50}) => [record];
  @override
  Future<void> load() async {}
  @override
  Future<void> verify(String id) async {}
  @override
  Future<OutputPackageInspection> inspectPackage(String id) async =>
      const OutputPackageInspection(
        status: 'kindle_container_checked',
        detail: '回执哈希、Palm记录边界和KF8格式头已检查；内容仍待核验。',
      );
}

class VisualLibrary extends Fake implements LibraryService, FolderCountService {
  @override
  Future<FolderCount> countFolder(
    String path, {
    required bool Function() cancelled,
  }) async =>
      FolderCount(path.contains('Archives') ? 52 : 18, true, '视觉夹具：本层电子书文件数量');

  final conversion = VisualConversion();
  final history = VisualChanges();
  final output = VisualOutput();
  @override
  final ValueNotifier<List<BookSummary>> books = ValueNotifier(const [
    BookSummary(
      id: 'river',
      title: '长河照影',
      author: '林间客',
      path: r'D:\书稿\长河照影.txt',
      format: 'TXT',
      chapters: 690,
      status: '已检查',
    ),
    BookSummary(
      id: 'sea',
      title: '山海来信',
      author: '无涯',
      path: r'D:\书稿\山海来信.epub',
      format: 'EPUB',
      chapters: 248,
      status: '已检查',
    ),
  ]);
  @override
  final ValueNotifier<BookSelection> selection = ValueNotifier(
    BookSelection('river', {'river', 'sea'}),
  );
  @override
  final ValueNotifier<bool> importing = ValueNotifier(false),
      projectBusy = ValueNotifier(false);
  @override
  final ValueNotifier<List<String>> favoriteFolders = ValueNotifier([
    r'D:\Books\待整理',
    r'D:\Books\Kindle 输出',
    r'D:\Archives\Novels',
  ]);
  @override
  final ValueNotifier<Map<String, String>> favoriteNames = ValueNotifier({
    r'D:\Books\待整理': '待整理小说',
    r'D:\Books\Kindle 输出': 'Kindle 成品',
    r'D:\Archives\Novels': '长篇存档',
  });
  @override
  String favoriteName(String path) =>
      favoriteNames.value[path] ?? path.split('\\').last;
  @override
  Future<bool> loadFavorites() async => true;
  @override
  ConversionSession openConversion() => conversion;
  @override
  ChangeHistoryService openChangeHistory() => history;
  @override
  OutputHistoryService openOutputHistory() => output;
}

class VisualPicker extends Fake implements BookFilePicker {}

class VisualDesktop extends Fake implements ConversionDesktop {
  @override
  Future<String?> bundledConverter() async =>
      r'D:\portable\converters\kindling.exe';
}

void main() {
  testWidgets('S7 renders every scene with new production widgets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    final root = Directory('../artifacts/frontend-rewrite/s7-visual');
    await tester.runAsync(() async {
      await root.create(recursive: true);
      for (final font in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(font.value).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
    });
    final fixtureCover = File('${root.absolute.path}/river-cover.png');
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(3);
      const bounds = Rect.fromLTWH(0, 0, 58, 84.1);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, const Offset(58, 84.1), [
            const Color(0xff23664f),
            Color.lerp(const Color(0xff23664f), Colors.black, .22)!,
          ]),
      );
      void text(
        String value,
        double size,
        double top, {
        bool bold = false,
        Color color = Colors.white70,
      }) {
        final painter = TextPainter(
          text: TextSpan(
            text: value,
            style: TextStyle(
              fontFamily: 'Microsoft YaHei',
              fontSize: size,
              height: 1.45,
              color: color,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 42.92);
        painter.paint(canvas, Offset(7.54, top));
        painter.dispose();
      }

      text('长 河 纪 事', 58 * .071, 7.54);
      text('长河照影', 58 * .17, 31.7, bold: true, color: Colors.white);
      text('林间客  著', 58 * .08, 54);
      final picture = recorder.endRecording();
      final image = await picture.toImage(174, 253);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await fixtureCover.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    });
    const scenes = [
      'conversion',
      'preflight',
      'preflight-blocked',
      'tasks',
      'output',
      'output-folder',
      'history',
    ];
    final captured = <String>[];
    for (final scene in scenes) {
      final library = VisualLibrary();
      if ([
        'conversion',
        'output-folder',
        'preflight-blocked',
      ].contains(scene)) {
        // The approved scene starts with unchecked manuscripts, independent of tasks.
        library.books.value = library.books.value
            .map(
              (b) => BookSummary(
                id: b.id,
                title: b.title,
                author: b.author,
                path: b.path,
                format: b.format,
                chapters: b.chapters,
                status: '待检查',
                coverPath: b.coverPath,
              ),
            )
            .toList();
      }
      library.conversion.blocked = scene == 'preflight-blocked';
      if (scene == 'tasks') {
        library.conversion.busy = true;
        library.conversion.outputs = [
          ConversionOutput(
            'river',
            '长河照影',
            r'D:\书稿\成品\长河照影.azw3',
            '生成中',
            phase: 'converting',
            format: 'AZW3',
            taskId: 'one',
            checksEnabled: true,
            coverPath: fixtureCover.path,
          ),
          ConversionOutput(
            'sea',
            '山海来信',
            r'D:\书稿\成品\山海来信.epub',
            '已完成',
            phase: 'complete',
            format: 'EPUB',
            taskId: 'two',
            historical: true,
          ),
          ConversionOutput(
            'rain',
            '听雨集',
            '',
            '失败',
            phase: 'failed',
            format: 'AZW3',
            detail: '输出文件夹不可写 · 修复后可重试',
            taskId: 'three',
            historical: true,
          ),
          ConversionOutput(
            'river',
            '长河照影',
            r'D:\书稿\成品\长河照影.epub',
            '已完成',
            phase: 'complete',
            format: 'EPUB',
            taskId: 'four',
            historical: true,
          ),
        ];
        library.conversion.historical = library.conversion.outputs
            .skip(1)
            .toList();
        library.conversion.outputs = library.conversion.outputs
            .take(1)
            .toList();
      }
      final boundary = GlobalKey();
      final route = scene == 'tasks'
          ? '/tasks'
          : scene == 'output'
          ? '/tasks/output/output'
          : scene == 'history'
          ? '/history'
          : '/conversion';
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: RewriteApp(
            key: ValueKey(scene),
            library: library,
            picker: VisualPicker(),
            conversionDesktop: VisualDesktop(),
            initialLocation: route,
          ),
        ),
      );
      // Bounded pumps also support indeterminate progress animations.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      if (scene.startsWith('preflight')) {
        await tester.tap(find.text('检查书稿'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      } else if (scene == 'output-folder') {
        await tester.tap(find.text('浏览'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.tap(find.text('Kindle 成品'));
        await tester.pump();
      }
      if (scene == 'tasks') {
        for (
          var i = 0;
          i < 100 &&
              find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
      expect(tester.takeException(), isNull, reason: scene);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${root.path}/$scene.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      captured.add(scene);
      if (scene == 'preflight') {
        expect(find.text('长河照影 · 章节编号跳跃 · 第 1 项'), findsNothing);
        await tester.tap(find.text('查看 2 项提醒'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('长河照影 · 章节编号跳跃 · 第 1 项').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('长河照影 · 章节编号跳跃 · 第 2 项').last);
        await tester.pumpAndSettle();
        expect(
          find.text('第120章至第122章编号不连续；请核对原文，不能仅凭编号判断正文缺失。'),
          findsOneWidget,
        );
        await tester.tap(find.text('查看全部检查'));
        await tester.pumpAndSettle();
        expect(find.text('长河照影 · 章节编号跳跃 · 第 1 项'), findsNothing);
        expect(find.text('源文件与编码'), findsOneWidget);
        final plan = await library.conversion.preview(
          library.conversion.request!,
        );
        expect(plan.findings.where((f) => f.level == 'pass').length, 8);
        expect(plan.findings.where((f) => f.level == 'warning').length, 2);
        expect(plan.findings.where((f) => f.level == 'blocking'), isEmpty);
        expect(plan.groups.length, 6);
        expect(
          plan.groups.firstWhere((g) => g.key == 'chapters').items.length,
          2,
        );
        await tester.tap(find.byTooltip('转换高级设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.textContaining(RegExp(r'^确认(保留并)?转换$')), findsOneWidget);
        await tester.tap(find.byTooltip('转换高级设置'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).last,
          r'D:\new\kindling.exe',
        );
        await tester.tap(find.text('采用设置'));
        await tester.pumpAndSettle();
        expect(find.textContaining(RegExp(r'^确认(保留并)?转换$')), findsNothing);
        expect(find.text('检查书稿'), findsOneWidget);
      }
      if (scene == 'tasks') {
        await tester.tap(find.byKey(const ValueKey('task-row-four')));
        await tester.pump();
        expect(find.text('长河照影.epub'), findsOneWidget);
        await tester.tap(find.text('听雨集'));
        await tester.pump();
        expect(find.text('未记录阶段结果'), findsNWidgets(3));
        expect(find.text('输出文件夹不可写 · 修复后可重试'), findsWidgets);
        expect(tester.takeException(), isNull);
      }
      if (scene == 'conversion') {
        await tester.tap(find.byTooltip('页面导航'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('变更记录'));
        await tester.pumpAndSettle();
        expect(find.text('变更记录'), findsOneWidget);
        await tester.tap(find.byTooltip('页面导航'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('转换设置'));
        await tester.pumpAndSettle();
        expect(find.text('转换设置'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      if (scene == 'history') {
        await tester.tap(find.text('第十二章 夜渡').first);
        await tester.pumpAndSettle();
        expect(find.text('返回顺序分页'), findsOneWidget);
        expect(find.text('目标所在页 · 从第 1 项'), findsNWidgets(2));
        await tester.tap(find.text('返回顺序分页'));
        await tester.pumpAndSettle();
        expect(find.text('下一页'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('选择记录书籍'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('山海来信').last);
        await tester.pumpAndSettle();
        expect(find.text('此范围暂无变更记录。'), findsOneWidget);
        await tester.tap(find.byTooltip('选择记录书籍'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('长河照影').last);
        await tester.pumpAndSettle();
        expect(find.text('此范围暂无变更记录。'), findsNothing);
        expect(find.text('修改前'), findsOneWidget);
      }
      if (scene == 'output-folder') {
        await tester.tap(find.text('使用此文件夹'));
        await tester.pumpAndSettle();
        expect(find.text('使用此文件夹'), findsNothing);
        await tester.tap(find.text('检查书稿'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('转换前自动检查'), findsOneWidget);
        expect(find.textContaining(RegExp(r'^确认(保留并)?转换$')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    expect(captured, scenes);
    await tester.runAsync(
      () => File('${root.path}/manifest.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'scenes': captured,
          'width': 2160,
          'height': 1440,
          'source':
              'new production widgets with visual-only application services',
          'accepted': false,
          'knownFixtureGaps': [
            'task progress unavailable in service contract',
            'folder book counts unavailable',
            'history timestamp and legacy structure replay unavailable',
            'Kindle content comparison and device acceptance pending',
          ],
          'businessEvidence': 'Separate real DLL tests required',
        }),
      ),
    );
  });
}
