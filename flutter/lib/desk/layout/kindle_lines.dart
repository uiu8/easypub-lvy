// Kindle（KPW5）中文断行：排版页小预览与章节页排版视图共用，规则与真机预览 plugins/kindle-preview 一致。
//
// 依据：后来按用户 KPW5 真机截图实测的规则，以及 2026-10-30 固件逆向交接包（KPW5 5.17.1.0.3
// libYJR-shared.so）中原函数执行得到的简体中文字符类别、间距描述与中文禁则码点集合：
// · 后置标点（类别 16 句号问号叹号、18 顿号分号冒号、19 逗号与闭括号类）在行末只占半个字宽；
//   后面紧跟另一个后置标点时，前一个只占半个字宽（间距描述 0、0）；
// · 段首全角空格或另一个前置标点之后的前置标点只占半个字宽；
// · 汉字与西文字母、数字相邻处多 0.075 个字宽（间距描述 19）；
// · 固件左侧禁则 17 项（不能放在行末）、右侧禁则 43 项（不能放在行首）；“——”“……”不拆开；
// ·（KPW5 宋体与苹方截图逐字同位）：弯引号与其他中文标点一样按一个字宽，与字体无关；后置引号在行末、
//   紧跟后置标点时半宽；后置标点紧跟前置标点时前一个半宽；省略号可以放在行首；
// · 除段末一行外两端对齐。
// 普通正文使用已逆向确认的候选评分比较，分页状态机另外处理孤行、寡行和
// 显式换页。旧 ARM 组保留其顺序扫描器，避免把新组比较器套到旧设备。
import 'dart:math' as math;
import 'dart:typed_data';

/// 固件排版管线分组。
///
/// 固件排版管线。旧设备虽然共用中文字符表，但候选扫描器不是同一个：
/// Voyage、KPW3/Oasis1/2、KPW4/Basic10 分别对应三套旧实现。
enum KindleLineEngine {
  legacy,
  legacyVoyage,
  legacyKpw3,
  legacyKpw4,
  kpw5,
  modern,
}

/// 五组固件排版管线共用的布局参数。
///
/// 各组使用同一套字符描述和禁则数据，差异集中在候选扫描器和比较器。
/// 这样小预览、排版视图和真机预览不会再各自维护一份“近似规则”。
class KindleLayoutProfile {
  const KindleLayoutProfile({
    required this.id,
    required this.engine,
    required this.scoredCandidates,
    required this.breakTolerance,
    required this.allowEllipsisAtLineStart,
    required this.tieBreakLast,
    this.defaultOrphans = 1,
    this.defaultWidows = 1,
    this.applyExplicitPagination = true,
  });

  final String id;
  final KindleLineEngine engine;
  final bool scoredCandidates;
  final double breakTolerance;
  final bool allowEllipsisAtLineStart;
  final bool tieBreakLast;

  /// 固件正文分页的最小页首、页尾行数。KFX 组由固件预览规则固定为 1，
  /// 旧组在网页预览中会优先使用原书 CSS 的值，缺省才回到这里。
  final int defaultOrphans;
  final int defaultWidows;

  /// 是否由统一状态机把已断好的行显式分配到页面。
  final bool applyExplicitPagination;
}

KindleLayoutProfile kindleLayoutProfile(KindleLineEngine engine) =>
    switch (engine) {
      KindleLineEngine.modern => const KindleLayoutProfile(
        id: 'modern',
        engine: KindleLineEngine.modern,
        scoredCandidates: true,
        breakTolerance: .001,
        allowEllipsisAtLineStart: true,
        tieBreakLast: true,
      ),
      KindleLineEngine.kpw5 => const KindleLayoutProfile(
        id: 'kpw5',
        engine: KindleLineEngine.kpw5,
        scoredCandidates: true,
        breakTolerance: .001,
        allowEllipsisAtLineStart: true,
        tieBreakLast: true,
      ),
      KindleLineEngine.legacyVoyage => const KindleLayoutProfile(
        id: 'legacy-voyage',
        engine: KindleLineEngine.legacyVoyage,
        scoredCandidates: false,
        breakTolerance: .001,
        allowEllipsisAtLineStart: false,
        tieBreakLast: true,
      ),
      KindleLineEngine.legacyKpw3 => const KindleLayoutProfile(
        id: 'legacy-kpw3',
        engine: KindleLineEngine.legacyKpw3,
        scoredCandidates: false,
        breakTolerance: .001,
        allowEllipsisAtLineStart: false,
        tieBreakLast: true,
      ),
      KindleLineEngine.legacyKpw4 ||
      KindleLineEngine.legacy => const KindleLayoutProfile(
        id: 'legacy-kpw4',
        engine: KindleLineEngine.legacyKpw4,
        scoredCandidates: false,
        breakTolerance: .001,
        allowEllipsisAtLineStart: false,
        tieBreakLast: true,
      ),
    };

KindleLineEngine kindleLineEngineForDevice(String id) => switch (id) {
  'kpw6' || 'colorsoft' || 'scribe' => KindleLineEngine.modern,
  'kpw5' || 'basic11' || 'oasis3' => KindleLineEngine.kpw5,
  'voyage' => KindleLineEngine.legacyVoyage,
  'kpw3' || 'oasis1' || 'oasis2' => KindleLineEngine.legacyKpw3,
  'kpw4' || 'basic10' => KindleLineEngine.legacyKpw4,
  _ => KindleLineEngine.legacy,
};

String kindleEngineGroupForDevice(String id) =>
    switch (kindleLineEngineForDevice(id)) {
      KindleLineEngine.modern => 'modern',
      KindleLineEngine.kpw5 => 'kpw5',
      KindleLineEngine.legacyVoyage => 'legacy-voyage',
      KindleLineEngine.legacyKpw3 => 'legacy-kpw3',
      KindleLineEngine.legacyKpw4 => 'legacy-kpw4',
      KindleLineEngine.legacy => 'legacy',
    };

/// 行末压成半宽、相邻挤压的后置标点。
const kindleClosing = '。，、；：？！」』）》】〉';

/// 相邻挤压时可以作为“后一个”的标点（含闭引号）。
const kindleClosingAll = '$kindleClosing”’';

/// 弯引号：不论字体，按一个字宽。
const kindleQuotes = '“”‘’';

/// 前置标点。
const kindleOpening = '“‘「『（《【〈';

/// 固件按整字处理的中文标点。不能使用字体实际 advance 判定是否“全角”，
/// 否则苹方的窄字形会把同一候选链错误地当成半角。
// KFX treats paired ellipses and em dashes as full-width CJK marks. Using
// the font advance here shifts the P10 punctuation probe by one character.
const kindleFullWidthMarks =
    '$kindleClosing$kindleOpening$kindleQuotes—…';

/// 固件左侧禁则（不能放在行末）：0028 002F 003C 005B 007B 2018 201C 3008 300A 300C 300E 3010 3014 3016 FF08 FF3B FF5B。
final kindleNoEnd = Set<int>.unmodifiable(const [
  0x28, 0x2F, 0x3C, 0x5B, 0x7B, 0x2018, 0x201C, 0x3008, 0x300A, //
  0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0xFF08, 0xFF3B, 0xFF5B,
]);

/// 固件右侧禁则（不能放在行首），43 项。
final kindleNoStart = Set<int>.unmodifiable(const [
  0x21, 0x29, 0x2C, 0x2D, 0x2E, 0x2F, 0x3A, 0x3B, 0x3E, 0x3F, //
  0x5D, 0x7D, 0x7E, 0xB7, 0x2013, 0x2014, 0x2019, 0x201D, 0x2022, 0x2027,
  0x203C, 0x2047, 0x3001, 0x3002, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011,
  0x3015, 0x3017, 0x30FB, 0xFF01, 0xFF09, 0xFF0C, 0xFF0E, 0xFF0F, 0xFF1A,
  0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D, 0xFF5E,
]);

bool _han(int c) =>
    (c >= 0x3040 && c <= 0x30FF) ||
    (c >= 0x3400 && c <= 0x9FFF) ||
    (c >= 0xF900 && c <= 0xFAFF);

bool _latin(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A);

double _f32(double value) => Float32List.fromList([value])[0].toDouble();

bool _isCjk(int c) => _han(c);

/// 固件 23 个间距描述的有限评分节点。节点来自 ARM 宽度函数的实际执行，
/// 每一行按字号 1 归一化，实际宽度再乘对应字体实例的 size。
const _descriptorScores = <double>[
  -7,
  -6,
  -5.5,
  -5,
  -4.5,
  -4,
  -3.5,
  -3,
  -2.5,
  -2,
  -1,
  0,
  1,
  2,
  2.5,
  3,
  4,
  7,
];

const _descriptorWidths = <List<double>>[
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, .0625, .125, 1.125, 4.125],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 4],
  [
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
  ],
  [
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    0.5,
    1.5,
    4.5,
  ],
  [0, 0, 0, 0, .25, .5, .5, .5, .5, .5, .5, .5, .5, .5, .5, .5, 1.5, 4.5],
  [0, 0, 0, 0, .25, .5, .5, .5, .5, .5, .5, .5, .5, .5, .5, .5, .5, .5],
  [
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .375,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    1.5,
    4.5,
  ],
  [
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .375,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
    .5,
  ],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, .5, .5, .5, .5, .5, .5, .5, .5, .5],
  [
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
  ],
  [0, 0, 0, 0, 0, 0, 0, 0, .125, .25, .25, .25, .25, .25, .25, .25, .25, .25],
  [
    0,
    0,
    0,
    0,
    0,
    0,
    .125,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
  ],
  [
    0,
    0,
    0,
    0,
    0,
    0,
    .125,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    1.25,
    4.25,
  ],
  [
    .125,
    .125,
    .1875,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
  ],
  [
    .125,
    .125,
    .1875,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .5,
    .5,
    .5,
    1.5,
    4.5,
  ],
  [
    .125,
    .125,
    .1875,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    1.25,
    4.25,
  ],
  [
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .5,
    .5,
    .5,
    1.5,
    4.5,
  ],
  [
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    1.25,
    4.25,
  ],
  [
    0,
    0,
    .0375,
    .075,
    .075,
    .075,
    .075,
    .075,
    .075,
    .075,
    .075,
    .075,
    .075,
    .075,
    .075,
    .075,
    1.075,
    4.075,
  ],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 2.5, 3, 4, 7],
  [
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    .25,
    1.25,
    2.25,
    2.75,
    3.25,
    4.25,
    7.25,
  ],
  [.5, .5, .5, .5, .5, .5, .5, .5, .5, .5, .5, .5, 1.5, 2.5, 3, 3.5, 4.5, 7.5],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1],
];

/// 固件字符描述表的可观察部分。
///
/// 描述符的完整曲线在固件中以 23 个编号保存。对行宽有影响的组合在这里
/// 统一折算为相邻字符之间的增量，编号与逆向交接文档保持一致。普通汉字
/// 默认使用描述符 1/1，中文与西文切换使用 19/2。
({int left, int right}) kindlePairDescriptor(int left, int right) {
  if (_isCjk(left) && _latin(right)) return (left: 19, right: 2);
  if (_latin(left) && _isCjk(right)) return (left: 2, right: 19);
  // 固件分类表中的标点对不是按 Unicode 名称推导的：逗号/句号
  // 后接正文时分别走 5/2 与 4/2，闭引号/左引号和括号对也有独立项。
  if (left == 0xFF0C &&
      (_isCjk(right) || kindleOpening.runes.contains(right))) {
    return (left: 5, right: 2);
  }
  if (left == 0x3002 && _isCjk(right)) {
    return (left: 4, right: 2);
  }
  if (left == 0x3002 && right == 0x201D) {
    return (left: 0, right: 0);
  }
  if (left == 0x201D && right == 0x201C) {
    return (left: 5, right: 2);
  }
  if (left == 0xFF09 && right == 0xFF08) {
    return (left: 5, right: 2);
  }
  if (left == 0x3001 && right == 0xFF0C) {
    return (left: 0, right: 0);
  }
  if (kindleClosingAll.runes.contains(left) &&
      (kindleClosingAll.runes.contains(right) ||
          kindleOpening.runes.contains(right))) {
    return (left: 0, right: 0);
  }
  if (kindleOpening.runes.contains(left) &&
      kindleOpening.runes.contains(right)) {
    return (left: 5, right: 2);
  }
  if (kindleNoStart.contains(right) || kindleNoEnd.contains(left)) {
    return (left: 0, right: 0);
  }
  return (left: 1, right: 1);
}

/// 描述符 19 的浮点宽度曲线。q 是候选行相对版心的伸缩量，S 是字号。
/// 该曲线只在中西文相邻时使用，避免把浏览器字体的实际字宽混入固件评分。
double kindleDescriptorWidth(int descriptor, double scale, double q) {
  if (descriptor < 1 || descriptor > _descriptorWidths.length || scale == 0) {
    return 0;
  }
  final row = _descriptorWidths[descriptor - 1];
  final value = _f32(q);
  if (value <= _descriptorScores.first) return _f32(scale * row.first);
  if (value >= _descriptorScores.last) {
    final i = _descriptorScores.length - 2;
    final t =
        (value - _descriptorScores[i]) /
        (_descriptorScores[i + 1] - _descriptorScores[i]);
    return _f32(scale * (row[i] + (row[i + 1] - row[i]) * t));
  }
  for (var i = 0; i + 1 < _descriptorScores.length; i++) {
    final left = _descriptorScores[i];
    final right = _descriptorScores[i + 1];
    if (value <= right) {
      final t = (value - left) / (right - left);
      return _f32(scale * (row[i] + (row[i + 1] - row[i]) * t));
    }
  }
  return _f32(scale * row.last);
}

double kindleDescriptorWidth19(double scale, double q) =>
    kindleDescriptorWidth(19, scale, q);

double kindleDescriptorPairWidth(
  int leftDescriptor,
  int rightDescriptor,
  double previousScale,
  double currentScale,
  double q,
) => _f32(
  kindleDescriptorWidth(leftDescriptor, previousScale, q) +
      kindleDescriptorWidth(rightDescriptor, currentScale, q),
);

double _kindleCandidateDescriptorScore(
  List<int> runes,
  int start,
  int end,
  double scale,
  double q,
) {
  var score = 0.0;
  for (var i = start; i + 1 < end; i++) {
    final pair = kindlePairDescriptor(runes[i], runes[i + 1]);
    score = _f32(
      score + kindleDescriptorPairWidth(pair.left, pair.right, scale, scale, q),
    );
  }
  return score;
}

/// 分页后的行引用。paragraph/line 都是从 0 开始的索引。
class KindlePageLine {
  const KindlePageLine(this.paragraph, this.line);

  final int paragraph;
  final int line;
}

class KindlePage {
  const KindlePage(this.lines);

  final List<KindlePageLine> lines;
}

/// 从固件管线取得分页默认值。旧管线的实际 orphans/widows 可能由 EPUB
/// 样式覆盖，网页入口会把计算样式传给同一状态机。
({int orphans, int widows}) kindlePaginationDefaults(KindleLineEngine engine) {
  final profile = kindleLayoutProfile(engine);
  return (orphans: profile.defaultOrphans, widows: profile.defaultWidows);
}

/// 按 Kindle 的段落状态、孤行/寡行和显式分页标记把已断好的行排入页面。
///
/// 这里的输入是同一段落已经经过 [kindleLines] 的行。状态机只决定行属于
/// 哪一页，因此不会再次使用浏览器的 widows/orphans 默认值，也不会把
/// `break-before`、`break-after` 交给 Chromium 自己解释。
List<KindlePage> kindlePaginate(
  List<List<KindleLine>> paragraphs, {
  required double height,
  required double lineHeight,
  double paragraphSpacing = 0,
  List<double>? paragraphSpacings,
  int orphans = 1,
  int widows = 1,
  List<bool>? keepWithNext,
  List<bool>? breakBefore,
  List<bool>? breakAfter,
}) {
  if (paragraphs.isEmpty) return const [];
  final pageHeight = math.max(lineHeight, height);
  final rowHeight = math.max(.001, lineHeight);
  final orphanCount = orphans.clamp(1, 15).toInt();
  final widowCount = widows.clamp(1, 15).toInt();
  final pages = <KindlePage>[];
  var current = <KindlePageLine>[];
  var used = 0.0;

  void finishPage() {
    if (current.isNotEmpty) {
      pages.add(KindlePage(List.unmodifiable(current)));
      current = <KindlePageLine>[];
      used = 0;
    }
  }

  int capacity({double spacing = 0}) {
    final available =
        pageHeight - used - spacing.clamp(0, double.infinity).toDouble();
    return math.max(0, (available / rowHeight).floor());
  }

  double spacingFor(int paragraph) =>
      paragraphSpacings != null && paragraph < paragraphSpacings.length
      ? math.max(0, paragraphSpacings[paragraph])
      : math.max(0, paragraphSpacing);

  for (var p = 0; p < paragraphs.length; p++) {
    final lines = paragraphs[p];
    if (lines.isEmpty) continue;
    if (breakBefore != null && p < breakBefore.length && breakBefore[p]) {
      finishPage();
    }
    if (keepWithNext != null &&
        p > 0 &&
        p - 1 < keepWithNext.length &&
        keepWithNext[p - 1] &&
        current.isNotEmpty &&
        capacity(spacing: spacingFor(p)) < lines.length) {
      finishPage();
    }
    var offset = 0;
    while (offset < lines.length) {
      final spacing = current.isEmpty ? 0.0 : spacingFor(p);
      var room = capacity(spacing: spacing);
      if (room < math.min(orphanCount, lines.length - offset)) {
        finishPage();
        room = capacity();
      }
      if (room <= 0) {
        finishPage();
        room = capacity();
      }
      final remaining = lines.length - offset;
      var take = math.min(room, remaining).toInt();
      if (take < remaining && remaining - take < widowCount) {
        final reduced = remaining - widowCount;
        if (reduced >= math.min(orphanCount, remaining) && reduced > 0) {
          take = reduced;
        } else {
          finishPage();
          continue;
        }
      }
      if (take <= 0) {
        finishPage();
        continue;
      }
      if (spacing > 0) used += spacing;
      for (var line = 0; line < take; line++) {
        current.add(KindlePageLine(p, offset + line));
      }
      used += take * rowHeight;
      offset += take;
      if (offset < lines.length) finishPage();
    }
    if (breakAfter != null && p < breakAfter.length && breakAfter[p]) {
      finishPage();
    }
  }
  finishPage();
  return List.unmodifiable(pages);
}

/// 一行：原文 UTF-16 区间 [start, end)，[spacing] 为这一行每个字符（按码点）后面要加的字距（像素，可为负）。
class KindleLine {
  const KindleLine(this.start, this.end, this.spacing);
  final int start, end;
  final List<double> spacing;
}

/// 按 Kindle 规则把一段分成行。[advance] 为单个字符（码点）的宽度（已含正文字距）；
/// [width] 为版心宽，[indent] 为首行缩进；[em] 为正文字号。[justify] 为 false 时不补两端对齐的字距。
List<KindleLine> kindleLines(
  String text, {
  required double width,
  required double em,
  required double Function(int codePoint) advance,
  double indent = 0,
  bool justify = true,
  KindleLineEngine engine = KindleLineEngine.kpw5,
}) {
  final runes = text.runes.toList();
  if (runes.isEmpty) return const [];
  final profile = kindleLayoutProfile(engine);
  final offsets = <int>[];
  var o = 0;
  for (final r in runes) {
    offsets.add(o);
    o += r > 0xFFFF ? 2 : 1;
  }
  offsets.add(o);
  final n = runes.length;
  // 弯引号按一个字宽排；画的时候字体里的实际宽度与一个字宽之差补进字距（drawFix）。
  final drawn = [for (final r in runes) advance(r)];
  final quote = [for (final r in runes) kindleQuotes.runes.contains(r)];
  final base = [
    for (var i = 0; i < n; i++)
      quote[i] || kindleFullWidthMarks.runes.contains(runes[i]) ? em : drawn[i],
  ];
  bool full(int i) =>
      quote[i] ||
      kindleFullWidthMarks.runes.contains(runes[i]) ||
      base[i] >= em * .9;
  // 后置标点（后来含后置引号）。
  final closing = [for (final r in runes) kindleClosingAll.runes.contains(r)];
  // 行中的固定调整：相邻后置标点、段首或连续的前置标点、汉字与西文间距。
  final adjust = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final c = runes[i];
    final next = i + 1 < n ? runes[i + 1] : -1;
    final pair = next >= 0 ? kindlePairDescriptor(c, next) : null;
    if (closing[i] &&
        full(i) &&
        next >= 0 &&
        pair != null &&
        pair.left == 0 &&
        pair.right == 0 &&
        (kindleClosingAll.runes.contains(next) ||
            kindleOpening.runes.contains(next))) {
      adjust[i] -= em / 2;
    }
    if (i > 0 &&
        kindleOpening.runes.contains(c) &&
        full(i) &&
        (runes[i - 1] == 0x3000 ||
            kindleOpening.runes.contains(runes[i - 1]))) {
      // 前置标点的左半边去掉：等于前一个字少占半个字宽。
      adjust[i - 1] -= em / 2;
    }
    if (next >= 0 &&
        pair != null &&
        ((pair.left == 19 && pair.right == 2) ||
            (pair.left == 2 && pair.right == 19))) {
      adjust[i] += kindleDescriptorWidth19(em, 0);
    }
    // Paired em dashes and ellipses stay together in the firmware candidate
    // chain and carry a small separation. This prevents an exact-width pair
    // from being rounded into the next Kindle column.
    if (next >= 0 && runes[i] == runes[i + 1] &&
        (runes[i] == 0x2014 || runes[i] == 0x2026)) {
      adjust[i] += em * .2;
    }
  }
  // 行末只占半个字宽（相邻挤压已经减过的不再减）。
  double endCut(int last) =>
      closing[last] && full(last) && adjust[last] >= 0 ? em / 2 : 0;
  // i 之前（i-1 与 i 之间）能否断行。
  bool breakable(int i) {
    if (i <= 0 || i >= n) return true;
    final a = runes[i - 1], b = runes[i];
    if (kindleNoStart.contains(b) || kindleNoEnd.contains(a)) return false;
    if (a == b && (a == 0x2014 || a == 0x2026)) return false;
    if (!profile.allowEllipsisAtLineStart && b == 0x2026) return false;
    if (_latin(a) && _latin(b)) return false;
    // 西文单词内部（字母后接撇号、连字符等）由上面的禁则处理；空格后可断。
    return true;
  }

  final lines = <KindleLine>[];
  var start = 0;
  var firstLine = true;
  while (start < n) {
    final avail = math.max(em, width - (firstLine ? indent : 0));
    var used = 0.0;
    var best = -1;
    var bestDistance = double.infinity;
    var i = start;
    for (; i < n; i++) {
      used += base[i] + adjust[i];
      final end = i + 1;
      final natural = used - endCut(i) - (adjust[i] > 0 ? adjust[i] : 0);
      // 固件候选扫描用 float32 宽度差再以 double 比较 0.001；使用 .01
      // 会把临界的 1016.4/1016 版心误判成同一条候选链。
      final naturalF32 = _f32(natural);
      if (naturalF32 - _f32(avail) >= profile.breakTolerance) {
        break;
      }
      if (end == n || breakable(end)) {
        if (profile.scoredCandidates) {
          // KPW5 与新组比较器先按候选的伸缩评分绝对值比较；对普通 CJK 行，
          // 评分单调等价于选最接近版心的候选。和固件一样，同分时
          // 后遍历到的候选胜出。
          final q = em == 0 ? 0.0 : _f32((avail - naturalF32) / em);
          // 描述符 19 的曲线参与同分比较。其权重只用于消除浮点同分，
          // 不改变普通 CJK 行的主排序。
          final descriptorScore = _kindleCandidateDescriptorScore(
            runes,
            start,
            end,
            em,
            q,
          );
          final distance = _f32(
            (avail - naturalF32).abs() + descriptorScore.abs() * 1e-6,
          );
          final improves =
              distance < bestDistance - 1e-7 ||
              (profile.tieBreakLast && distance <= bestDistance + 1e-7);
          if (improves) {
            best = end;
            bestDistance = distance;
          }
        } else {
          best = end;
        }
      }
    }
    if (best <= start) {
      // 一个可断点都放不下（超长西文词等）：放得下多少放多少，至少一个字。
      best = math.max(start + 1, i);
    }
    final count = best - start;
    final spacing = [for (var k = start; k < best; k++) adjust[k]];
    final last = best == n;
    final cut = endCut(best - 1);
    spacing[count - 1] -= cut;
    // 行末的中西间距不占宽度。
    if (adjust[best - 1] > 0) spacing[count - 1] -= adjust[best - 1];
    if (justify && !last && count > 1) {
      var natural = 0.0;
      for (var k = 0; k < count; k++) {
        natural += base[start + k] + spacing[k];
      }
      final extra = avail - natural;
      if (extra > 0) {
        final each = extra / (count - 1);
        for (var k = 0; k < count - 1; k++) {
          spacing[k] += each;
        }
      }
    }
    for (var k = 0; k < count; k++) {
      if (quote[start + k]) spacing[k] += em - drawn[start + k];
    }
    lines.add(KindleLine(offsets[start], offsets[best], spacing));
    start = best;
    firstLine = false;
  }
  return lines;
}
