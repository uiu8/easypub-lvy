// 整行【】的用途（V121，LAY-169）：与 Rust `system_scope.rs` 同一套规则，供排版页小预览判断系统提示。
// 网文里【】除了系统提示，还常用来写角色台词或心声、聊天消息、书前标签与作者说明：
// 逐行按内容分类，再按全书（小预览里是本章）倾向决定拿不准的行。
import 'layout_service.dart' show isSystemLine;

/// 识别范围：值与 Rust `SYSTEM_SCOPES` 一一对应。
const systemScopes = {'auto': '自动判断', 'all': '所有整行【】', 'keyword': '只认含系统用语'};

enum BracketKind { system, speech, chat, note, unsure }

final _strong = RegExp(
  r'叮|系统|宿主|任务|奖励|获得|获取|恭喜|检测到|解锁|升级|等级|经验|属性|技能|积分|签到|抽奖|好感度|倒计时|冷却|兑换|绑定|成就|称号|主线|支线|面板|技能点|属性点|天赋点|剩余时间|进度条|[lL][vV]\s*\.?\s*\d|[+＋]\s*\d|\d+\s*[/／]\s*\d+|\d+(\.\d+)?\s*[%％]',
);
final _valueNumber = RegExp(
  r'[：:]\s*[-+－＋]?\d+(\.\d+)?\s*[^\p{Script=Han}]{0,3}$',
  unicode: true,
);
final _talk = RegExp(r'[我咱俺]|老子|爷|[呢吧啊呀嘛哈哦噢唉哎咳咴哼喂嘿啦哇呗]');
final _weakTalk = RegExp(r'[你他她吗？！?!]');
final _weakSystem = RegExp(
  r'您|请|已|当前|目标|检测|余额|申请|查收|提醒|通知|注意|欢迎|是否|成功|失败|完成|开启|启动|加载|正在',
);
final _keyValue = RegExp(r'^【[^：:【】，。！？]{1,6}[：:][^，。！？；【】]{1,14}】$');
final _note = RegExp(r'^(叠甲|\d+[.．]\d+新编|新编|原书名|PS|ps|作者)|^\d{1,2}月\d{1,2}日');
const _speechVerbs = '说道问答喊叫笑骂叹吼言曰云称嚷哭';
const _namePunctuation = '，。！？、；“”‘’《》（）()【】[]［］<>…—·,.!?;"\'';

String _inner(String line) {
  final out = StringBuffer();
  var rest = line.trim();
  while (true) {
    final start = rest.indexOf('【');
    if (start < 0) break;
    final end = rest.indexOf('】', start + 1);
    if (end < 0) break;
    out.write(rest.substring(start + 1, end));
    rest = rest.substring(end + 1);
  }
  return out.toString();
}

/// 聊天消息的名字与内容（与 Rust `insets::chat_line` 同一规则）。
(String, String)? _chat(String line) {
  var t = line.trim();
  for (final (open, close) in const [('【', '】'), ('[', ']'), ('［', '］')]) {
    if (t.startsWith(open) && t.endsWith(close)) {
      final inner = t.substring(open.length, t.length - close.length);
      if (!inner.contains(open) && !inner.contains(close)) {
        t = inner.trim();
        break;
      }
    }
  }
  final runes = t.runes.toList();
  var pos = -1;
  for (var i = 0; i < runes.length && i < 8; i++) {
    if (runes[i] == 0xFF1A || runes[i] == 0x3A) {
      pos = i;
      break;
    }
  }
  if (pos < 0) return null;
  final name = String.fromCharCodes(runes.sublist(0, pos)).trim();
  final n = name.runes.length;
  if (n == 0 ||
      n > 6 ||
      name.runes.any(
        (c) =>
            String.fromCharCode(c).trim().isEmpty ||
            _namePunctuation.contains(String.fromCharCode(c)),
      ) ||
      RegExp(r'^\d+$').hasMatch(name) ||
      (n >= 2 && _speechVerbs.contains(name.substring(name.length - 1))) ||
      name.toLowerCase() == 'ps') {
    return null;
  }
  final say = String.fromCharCodes(runes.sublist(pos + 1)).trim();
  if (say.isEmpty || '“"「『‘\''.contains(say[0])) return null;
  return (name, say);
}

bool _chatty(String line, String say) =>
    (_talk.hasMatch(say) || _weakTalk.hasMatch(say)) &&
    !_keyValue.hasMatch(line.trim()) &&
    !_strong.hasMatch(say);

/// 一行整行【】的用途；不是整行【】时为空。[speakers] 是发过聊天消息的名字。
BracketKind? bracketKind(String line, Set<String> speakers) {
  if (!isSystemLine(line)) return null;
  final t = line.trim();
  final s = _inner(t);
  final pluses = '+＋'.runes.fold(
    0,
    (n, c) => n + s.runes.where((r) => r == c).length,
  );
  if (_note.hasMatch(s) || (pluses >= 2 && !RegExp(r'\d').hasMatch(s))) {
    return BracketKind.note;
  }
  final chat = _chat(t);
  if (chat != null && (speakers.contains(chat.$1) || _chatty(t, chat.$2))) {
    return BracketKind.chat;
  }
  if (_strong.hasMatch(s) || _valueNumber.hasMatch(s)) {
    return BracketKind.system;
  }
  if (_keyValue.hasMatch(t)) return BracketKind.system;
  if (_talk.hasMatch(s)) return BracketKind.speech;
  if (_weakSystem.hasMatch(s)) return BracketKind.system;
  if (_weakTalk.hasMatch(s)) return BracketKind.speech;
  return BracketKind.unsure;
}

/// 一组行（全书或本章）的整行【】判断。
class SystemScope {
  SystemScope(Iterable<String> lines, [String mode = 'auto'])
    : mode = systemScopes.containsKey(mode) ? mode : 'auto' {
    final brackets = [
      for (final l in lines)
        if (isSystemLine(l)) l.trim(),
    ];
    final said = <String, int>{};
    for (final line in brackets) {
      final chat = _chat(line);
      if (chat != null && _chatty(line, chat.$2)) {
        said[chat.$1] = (said[chat.$1] ?? 0) + 1;
      }
    }
    final speakers = {
      for (final e in said.entries)
        if (e.value >= 2) e.key,
    };
    for (final line in brackets) {
      final k = bracketKind(line, speakers)!;
      counts[k] = (counts[k] ?? 0) + 1;
      _kinds[line] = k;
    }
    systemBook =
        (counts[BracketKind.system] ?? 0) >=
        (counts[BracketKind.speech] ?? 0) + (counts[BracketKind.chat] ?? 0);
  }

  final String mode;
  final _kinds = <String, BracketKind>{};
  final counts = <BracketKind, int>{};
  late final bool systemBook;

  /// 这一行按系统提示排吗（只对整行【】为真）。
  bool isSystem(String line) {
    if (!isSystemLine(line)) return false;
    if (mode == 'all') return true;
    final k = _kinds[line.trim()] ?? bracketKind(line, const {})!;
    return switch (k) {
      BracketKind.system => true,
      BracketKind.speech || BracketKind.unsure => mode == 'auto' && systemBook,
      BracketKind.chat || BracketKind.note => false,
    };
  }
}
