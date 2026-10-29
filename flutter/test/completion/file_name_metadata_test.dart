import 'dart:io';

import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/file_name_metadata.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/file_name_author_settings.dart';

/// V72：从文件名取书名和作者（LIB-116）。
void main() {
  (String, String) parse(String name) {
    final m = fileNameMetadata(name);
    return (m.title, m.author);
  }

  test('认得出的写法', () {
    expect(parse('《希灵帝国》（校对版全本）作者：远瞳.txt'), ('希灵帝国', '远瞳'));
    expect(parse('《希灵帝国》作者：远瞳.txt'), ('希灵帝国', '远瞳'));
    expect(parse(r'D:\书\《诡秘之主》作者:爱潜水的乌贼.TXT'), ('诡秘之主', '爱潜水的乌贼'));
    expect(parse('《雪中悍刀行》.txt'), ('雪中悍刀行', ''));
    expect(parse('道诡异仙 作者：狐尾的笔.txt'), ('道诡异仙', '狐尾的笔'));
    expect(parse('道诡异仙_作者：狐尾的笔（完结）.txt'), ('道诡异仙', '狐尾的笔'));
    expect(parse('凡人修仙传（精校版）作者：忘语.epub'), ('凡人修仙传', '忘语'));
    expect(parse('《三体》作者：刘慈欣 著.txt'), ('三体', '刘慈欣'));
    // V107：书源插件默认的“书名 - 作者”。
    expect(parse('诡秘之主 - 爱潜水的乌贼.txt'), ('诡秘之主', '爱潜水的乌贼'));
    expect(parse('精灵女王审讯录 - 社畜宅宅 (1).txt'), ('精灵女王审讯录', '社畜宅宅'));
  });

  test('“书名 - 作者”：后半段像分册或章节、分隔不止一处、两边没空格时不猜', () {
    for (final name in [
      '斗罗大陆 - 第二部',
      '三体 - 2',
      '红楼梦 - 上',
      '雪中悍刀行 - 卷一',
      '某某 - 甲 - 乙',
      '诡秘之主-爱潜水的乌贼',
    ]) {
      expect(parse('$name.txt'), (name, ''), reason: name);
    }
  });

  test('TXT 开头的“书名 / 作者：”', () {
    expect(
      txtHeaderMetadata(
        '精灵女王审讯录\n作者：社畜宅宅\n\n简介：\n……',
        r'D:\下载\精灵女王审讯录.txt',
      )?.author,
      '社畜宅宅',
    );
    expect(
      txtHeaderMetadata('\uFEFF雾港来信\r\n作者:林岚\r\n', '雾港来信 - 林岚.txt')?.title,
      '雾港来信',
    );
    // 第一行不是文件名开头（正文第一句）、没有“作者：”、只有一行时不用。
    expect(txtHeaderMetadata('第一章 远行\n作者：某某\n', '雾港来信.txt'), isNull);
    expect(txtHeaderMetadata('雾港来信\n第一章 远行\n', '雾港来信.txt'), isNull);
    expect(txtHeaderMetadata('雾港来信', '雾港来信.txt'), isNull);
  });

  test('认不出时原样保留文件名，不猜作者', () {
    expect(parse('山海之间.txt'), ('山海之间', ''));
    // 括号里没有版本字样的不去掉。
    expect(parse('红楼梦（上）作者：曹雪芹.txt'), ('红楼梦（上）', '曹雪芹'));
    // 只有“作者：”没有书名。
    expect(parse('作者：某某.txt'), ('作者：某某', ''));
    expect(parse('《》作者：某某.txt'), ('《》作者：某某', ''));
    // 过长的“作者”不采用。
    expect(parse('书名 作者：${'长' * 31}.txt').$2, '');
  });

  test('书名(作者)、下载重复编号；括号里是分册或数字时不当作者', () {
    expect(parse('沧元图(我吃西红柿) (1).txt'), ('沧元图', '我吃西红柿'));
    expect(parse('大道朝天(猫腻) (2).txt'), ('大道朝天', '猫腻'));
    expect(parse('东京：从租借男友开始当完美男神(圭寸笔).txt'), ('东京：从租借男友开始当完美男神', '圭寸笔'));
    expect(parse('疯巫妖的实验日志(愤怒的松鼠) (1).txt'), ('疯巫妖的实验日志', '愤怒的松鼠'));
    expect(parse('剑来（烽火戏诸侯）.txt'), ('剑来', '烽火戏诸侯'));
    expect(parse('凡人修仙传（精校版）(忘语).txt'), ('凡人修仙传', '忘语'));
    // 版本说明去掉，不当作者。
    expect(parse('凡人修仙传（精校版）.txt'), ('凡人修仙传', ''));
    // 分册、卷次、数字。
    for (final name in [
      '红楼梦（上）',
      '三体(2)',
      '斗罗大陆（第二部）',
      '雪中悍刀行(卷一)',
      '诡秘之主（番外）',
      '全职高手（十）',
    ]) {
      expect(parse('$name.txt'), (name, ''), reason: name);
    }
    // 重复编号前必须有空格；书名里的“（2）”不动。
    expect(parse('红楼梦（2）.txt'), ('红楼梦（2）', ''));
  });

  test('自定义格式、不提取、书名里保留作者名', () {
    (String, String) with_(String name, FileNameOptions o) {
      final m = fileNameMetadata(name, o);
      return (m.title, m.author);
    }

    const dash = FileNameOptions(mode: 'custom', pattern: '{作者} - {书名}');
    expect(with_('爱潜水的乌贼 - 诡秘之主.txt', dash), ('诡秘之主', '爱潜水的乌贼'));
    expect(with_('诡秘之主.txt', dash), ('诡秘之主', ''));
    // 不符合格式时按自动识别（V107）。
    expect(with_('剑来(烽火戏诸侯).txt', dash), ('剑来', '烽火戏诸侯'));
    // 多行：按顺序逐行尝试，用第一个符合的。
    const many = FileNameOptions(
      mode: 'custom',
      pattern: '[{*}]{书名}_{作者}\n{作者}：{书名}\n',
    );
    expect(many.patterns, ['[{*}]{书名}_{作者}', '{作者}：{书名}']);
    expect(isValidFileNamePattern(many.pattern), true);
    expect(with_('[精校]剑来_烽火戏诸侯.txt', many), ('剑来', '烽火戏诸侯'));
    expect(with_('猫腻：将夜.txt', many), ('将夜', '猫腻'));
    expect(isValidFileNamePattern('{书名}\n{作者}'), false, reason: '有一行无效就不能用');
    const tagged = FileNameOptions(mode: 'custom', pattern: '[{*}]{书名}_{作者}');
    expect(with_('[精校]剑来_烽火戏诸侯 (1).txt', tagged), ('剑来', '烽火戏诸侯'));
    // 格式无效（没有书名、两个作者）时按自动识别。
    for (final bad in ['{作者}', '{书名}{作者}{作者}', '书名']) {
      expect(isValidFileNamePattern(bad), false, reason: bad);
      expect(
        with_('剑来(烽火戏诸侯).txt', FileNameOptions(mode: 'custom', pattern: bad)),
        ('剑来', '烽火戏诸侯'),
      );
    }
    expect(with_('剑来(烽火戏诸侯) (1).txt', const FileNameOptions(mode: 'off')), (
      '剑来(烽火戏诸侯)',
      '',
    ));
    expect(
      with_('剑来(烽火戏诸侯) (1).txt', const FileNameOptions(stripAuthor: false)),
      ('剑来(烽火戏诸侯)', '烽火戏诸侯'),
    );
    // 设置读取：缺省为自动识别、默认格式、去掉作者名。
    final o = FileNameOptions.fromConfiguration({});
    expect((o.mode, o.pattern, o.stripAuthor), ('auto', '{书名}({作者})', true));
    final c = FileNameOptions.fromConfiguration({
      'filename_author_mode': 'custom',
      'filename_pattern': '{作者}-{书名}',
      'filename_strip_author': false,
    });
    expect((c.mode, c.pattern, c.stripAuthor), ('custom', '{作者}-{书名}', false));
  });

  test('导入 TXT 时书名、作者取自文件名', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v72-')).absolute;
    final file = File('${root.path}/《雾港来信》（校对版全本）作者：林岚.txt')
      ..writeAsStringSync('第一章 远行\n山路很长。\n第二章 归来\n海风很轻。\n');
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    final outcome = (await library.importFiles([file.path])).single;
    expect(outcome.succeeded, true, reason: outcome.message);
    final book = library.books.value.single;
    expect(book.title, '雾港来信');
    expect(book.author, '林岚');
    final information = library.openBookInformation(book.id);
    addTearDown(information.dispose);
    expect(information.saved['title'], '雾港来信');
    expect(information.saved['author'], '林岚');

    // 刷新来源：文件名里的书名、作者作为候选给出。
    final refresh = await library.previewSourceRefresh(book.id);
    expect(refresh.incoming['title'], '雾港来信');
    expect(refresh.incoming['author'], '林岚');

    // 书源下载的 TXT：文件名里没有作者，开头写着“书名 / 作者：”（V107）。
    final downloaded = File('${root.path}/海港夜话.txt')
      ..writeAsStringSync('海港夜话\n作者：沈舟\n\n\n第一章 远行\n\n　　山路很长。\n');
    expect(
      (await library.importFiles([downloaded.path])).single.succeeded,
      true,
    );
    final fromHeader = library.books.value.firstWhere((b) => b.title == '海港夜话');
    expect(fromHeader.author, '沈舟');

    // 改用自定义格式并保留书名里的作者名后，再导入一本。
    await library.savePatch({
      'filename_author_mode': 'custom',
      'filename_pattern': '{作者} - {书名}',
      'filename_strip_author': false,
    });
    final second = File('${root.path}/林岚 - 山海之间 (1).txt')
      ..writeAsStringSync('第一章 远行\n山路很长。\n');
    expect((await library.importFiles([second.path])).single.succeeded, true);
    final added = library.books.value.firstWhere(
      (b) => b.id != book.id && b.id != fromHeader.id,
    );
    expect(added.title, '林岚 - 山海之间');
    expect(added.author, '林岚');
  });

  testWidgets('设置 · 导入：切换方式、应用自定义格式、试一试即时显示结果', (t) async {
    final configuration = <String, dynamic>{};
    final saves = <Map<String, dynamic>>[];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: FileNameAuthorSettings(
                configuration: configuration,
                saving: false,
                save: (patch) async {
                  saves.add(patch);
                  setState(() => configuration.addAll(patch));
                  return true;
                },
              ),
            ),
          ),
        ),
      ),
    );
    final results = find.byKey(const ValueKey('settings-filename-results'));
    // 默认自动识别：示例第一行是“沧元图(我吃西红柿) (1).txt”。
    expect(
      find.descendant(of: results, matching: find.text('沧元图')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: results, matching: find.text('我吃西红柿')),
      findsOneWidget,
    );
    // 自动识别时格式框不可编辑。
    expect(
      t
          .widget<TextField>(
            find.byKey(const ValueKey('settings-filename_pattern')),
          )
          .enabled,
      false,
    );
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('settings-filename_author_mode')),
        matching: find.text('自定义格式'),
      ),
    );
    await t.pump();
    expect(saves.last, {'filename_author_mode': 'custom'});
    await t.enterText(
      find.byKey(const ValueKey('settings-filename_pattern')),
      '{作者} - {书名}',
    );
    await t.enterText(
      find.byKey(const ValueKey('settings-filename-sample')),
      '猫腻 - 将夜.txt',
    );
    await t.pump();
    // 保存前试一试已按编辑中的格式显示。
    expect(
      find.descendant(of: results, matching: find.text('将夜')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: results, matching: find.text('猫腻')),
      findsOneWidget,
    );
    await t.tap(find.byKey(const ValueKey('settings-filename_pattern-apply')));
    await t.pump();
    expect(saves.last, {'filename_pattern': '{作者} - {书名}'});
    // 无效格式：提示错误，不能应用。
    await t.enterText(
      find.byKey(const ValueKey('settings-filename_pattern')),
      '{作者}',
    );
    await t.pump();
    expect(find.text('每行需要恰好一个 {书名}，{作者} 最多一个'), findsOneWidget);
    expect(
      t
          .widget<DeskButton>(
            find.byKey(const ValueKey('settings-filename_pattern-apply')),
          )
          .onPressed,
      isNull,
    );
    await t.tap(find.byType(Switch));
    await t.pump();
    expect(saves.last, {'filename_strip_author': false});
    expect(t.takeException(), isNull);
  });
}
