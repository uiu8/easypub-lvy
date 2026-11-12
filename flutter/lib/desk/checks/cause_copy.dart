// 成片原因的文字：列表里的一行、右侧说明、例子和按钮，都从这里出，保证两处说法一致。
import '../../application/chapter_service.dart';

/// 列表与说明标题。
String causeTitle(ChapterIssueCause c) => switch (c.kind) {
  'unrecognized' => '有标题没被认成章节',
  'twin' => '同一章存了两遍',
  'misnumbered' => '章号和前后接不上',
  'echo' => '正文开头又写了一遍标题',
  'prose' => '正文句子被当成了标题',
  'no-prefix' => '标题没带“第”',
  _ => '成片出现的问题',
};

/// 数量：“354 章”“66 处”。
String causeCount(ChapterIssueCause c) =>
    '${c.count} ${c.kind == 'twin' || c.kind == 'misnumbered' ? '章' : '处'}';

int _linked(ChapterIssueCause c) => c.linked.values.fold(0, (a, b) => a + b);

/// 列表里标题下面的一句。
String causeHint(ChapterIssueCause c) {
  final linked = _linked(c);
  return switch (c.kind) {
    'unrecognized' => '多半是整本书用了另一种标题写法',
    'twin' => linked > 0 ? '带出 $linked 处跳号、编号回退' : '多出来的一份可以整批排除',
    'misnumbered' => '带出 $linked 处跳号、编号回退',
    'echo' => '可以整批去掉重复的那一行',
    'prose' => '可以整批还原为正文',
    'no-prefix' => '可以整批补上，也可能是作者的写法',
    _ => '',
  };
}

/// 右侧说明：这是什么、为什么会这样、处理后会怎样。
String causeBody(ChapterIssueCause c) {
  final linked = _linked(c);
  switch (c.kind) {
    case 'unrecognized':
      return '正文里有 ${c.count} 行像章节标题（比如“001：标题”这样数字开头的行），按现在的识别规则没有收进目录。'
          '多半是整本书用了另一种标题写法。\n可以一次全部设为章节，正文不变；纯数字开头的还可以统一写成“第X章 标题”。';
    case 'twin':
      final exact = c.count - c.near;
      final parts = [
        if (exact > 0) '$exact 章两份逐字相同',
        if (c.near > 0) '${c.near} 章只差几行或其中一份短了一截（多半是推广语，或者没下全）',
      ].join('，');
      return '这本书有 ${c.count} 章各存了两份'
          '${c.runs > 0 && c.runs < c.count ? '，连成 ${c.runs} 段' : ''}：$parts。'
          '${linked > 0 ? '\n检查另外报的 $linked 处跳号、编号重复或回退是多出来的那一份带出来的，排除后会一起消失。' : ''}';
    case 'misnumbered':
      return '有 ${c.count} 章的章号和前后两章接不上：前一章是 N，后一章是 N+2，这一章却写成了别的号。'
          '常见于作者笔误，或者两套编号交替出现。\n按前后两章把章号改回去后，$linked 处跳号、编号回退会一起消失。只改标题里的数字，不动正文。';
    case 'echo':
      return '有 ${c.count} 处标题在下面紧跟着又写了一遍（常少了空格，或少了括号里的求票、更新说明），'
          '被当成了另一章，于是报成同一个章号出现两次。\n去掉重复的那一行，正文归到前一个标题下面，文字不删。';
    case 'prose':
      return '有 ${c.count} 行正文以“第几章”“第几卷”这样的字开头，被收进了目录，其实是一句话或作者留言。'
          '\n还原为正文后它们不再出现在目录里，文字不删。建议先在预览里扫一眼，把真的标题取消勾选。';
    case 'no-prefix':
      return '有 ${c.count} 个标题写成“六百五十八章 回归”这样，没带“第”。软件已经把它们认成章节，目录不受影响。'
          '\n想统一就整批补上“第”；如果是作者的写法、想保持原样，选“不再提示”。';
  }
  return '';
}

/// 主按钮上的字。
String causeAction(ChapterIssueCause c) => switch (c.kind) {
  'unrecognized' => '预览并全部设为章节…',
  'twin' => '预览并排除多出来的一份…',
  'misnumbered' => '预览并改正章号…',
  'echo' => '预览并去掉重复的标题…',
  'prose' => '预览并还原为正文…',
  'no-prefix' => '预览并补上“第”…',
  _ => '预览修改…',
};

/// 批量修复弹窗标题里的名字。
String causeDialogLabel(ChapterIssueCause c) => causeTitle(c);

/// 一个例子的两栏文字（左、右）和备注。
(String, String, String) causeSample(
  ChapterIssueCause c,
  ChapterIssueCauseSample s,
) {
  String at(int index) =>
      index < s.lines.length ? '  第 ${s.lines[index]} 行' : '';
  switch (c.kind) {
    case 'twin':
      final note = switch (s.subtype) {
        'partial' => '其中一份短了一截',
        'near' =>
          (s.differingLines ?? 0) == 0
              ? '正文相同，标题不同'
              : '差 ${s.differingLines} 行',
        _ => '逐字相同',
      };
      final title = s.title.contains('：')
          ? s.title.substring(s.title.indexOf('：') + 1)
          : s.title;
      return (
        '${s.beforeTitle ?? title}${at(0)}',
        '${s.afterTitle ?? title}${at(1)}',
        note,
      );
    case 'misnumbered':
      return (
        '${s.title}${at(0)}',
        '前一章：${s.beforeTitle ?? ''}　后一章：${s.afterTitle ?? ''}',
        '应为第 ${s.expected} ${s.unit ?? '章'}',
      );
  }
  return (
    '${s.heading ?? s.title}${at(s.lines.length - 1)}',
    '',
    c.kind == 'echo' ? '和上一行的标题重复' : '',
  );
}
