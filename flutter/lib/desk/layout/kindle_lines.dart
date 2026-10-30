// Kindle（KPW5）中文断行（V124）：排版页小预览与章节页排版视图共用，规则与真机预览 plugins/kindle-preview 一致。
//
// 依据：V118 起按用户 KPW5 真机截图实测的规则，以及 2026-10-30 固件逆向交接包（KPW5 5.17.1.0.3
// libYJR-shared.so）中原函数执行得到的简体中文字符类别、间距描述与中文禁则码点集合：
// · 后置标点（类别 16 句号问号叹号、18 顿号分号冒号、19 逗号与闭括号类）在行末只占半个字宽；
//   后面紧跟另一个后置标点时，前一个只占半个字宽（间距描述 0、0）；
// · 段首全角空格或另一个前置标点之后的前置标点只占半个字宽；
// · 汉字与西文字母、数字相邻处多 0.075 个字宽（间距描述 19）；
// · 固件左侧禁则 17 项（不能放在行末）、右侧禁则 43 项（不能放在行首）；“——”“……”不拆开；
// · 除段末一行外两端对齐。
// 这是普通中文正文的近似模型，不是完整的 Kindle 排版引擎：没有实现伸缩评分选择断点、孤行回退等。
import 'dart:math' as math;

/// 行末压成半宽、相邻挤压的后置标点。
const kindleClosing = '。，、；：？！」』）》】〉';

/// 相邻挤压时可以作为“后一个”的标点（含闭引号）。
const kindleClosingAll = '$kindleClosing”’';

/// 前置标点。
const kindleOpening = '“‘「『（《【〈';

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
}) {
  final runes = text.runes.toList();
  if (runes.isEmpty) return const [];
  final offsets = <int>[];
  var o = 0;
  for (final r in runes) {
    offsets.add(o);
    o += r > 0xFFFF ? 2 : 1;
  }
  offsets.add(o);
  final n = runes.length;
  final base = [for (final r in runes) advance(r)];
  // 全角标点才挤压：比例宽度的字体里本来就窄的不再减。
  bool full(int i) => base[i] >= em * .9;
  final closing = [for (final r in runes) kindleClosing.runes.contains(r)];
  // 行中的固定调整：相邻后置标点、段首或连续的前置标点、汉字与西文间距。
  final adjust = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final c = runes[i];
    final next = i + 1 < n ? runes[i + 1] : -1;
    if (closing[i] &&
        full(i) &&
        next >= 0 &&
        kindleClosingAll.runes.contains(next)) {
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
    if (next >= 0 && ((_han(c) && _latin(next)) || (_latin(c) && _han(next)))) {
      adjust[i] += em * .075;
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
    // 省略号不放行首：固件的 43 项里没有，由 ICU 行边界规则（UAX #14 LB22）排除。
    if (b == 0x2026) return false;
    if (a == b && (a == 0x2014 || a == 0x2026)) return false;
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
    var i = start;
    for (; i < n; i++) {
      used += base[i] + adjust[i];
      final end = i + 1;
      if (used - endCut(i) - (adjust[i] > 0 ? adjust[i] : 0) > avail + .01) {
        break;
      }
      if (end == n || breakable(end)) best = end;
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
    lines.add(KindleLine(offsets[start], offsets[best], spacing));
    start = best;
    firstLine = false;
  }
  return lines;
}
