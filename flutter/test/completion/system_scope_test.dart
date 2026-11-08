import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/system_scope.dart';

/// V121（LAY-169）：整行【】的用途，与 Rust `system_scope.rs` 的测试用同样的例子。
void main() {
  test('台词多的书只认明确带系统用语的行', () {
    const text =
        '正文。\n【咴——他马的我料呢？】\n【你看你马呢？赶紧给老子上料啊！】\n【咴？？？】\n【……】\n【叮！获得技能：识马 LV1】\n';
    final scope = SystemScope(text.split('\n'));
    expect(scope.systemBook, false);
    expect(bracketKind('【咴——他马的我料呢？】', const {}), BracketKind.speech);
    expect(bracketKind('【……】', const {}), BracketKind.unsure);
    expect(scope.isSystem('【咴——他马的我料呢？】'), false);
    expect(scope.isSystem('【……】'), false);
    expect(scope.isSystem('【叮！获得技能：识马 LV1】'), true);
    expect(scope.isSystem('正文。'), false);
    expect(SystemScope(text.split('\n'), 'all').isSystem('【咴？？？】'), true);
  });

  test('系统提示多的书，拿不准的也算系统提示', () {
    const text =
        '【姓名：羽住悠】\n【年龄：18】\n【德：C】\n【宿主不属于这个时空，无法看清他人的相貌】\n【正在绑定......】\n【什么时间都有】\n';
    final scope = SystemScope(text.split('\n'));
    expect(scope.systemBook, true);
    expect(bracketKind('【姓名：羽住悠】', const {}), BracketKind.system);
    expect(scope.isSystem('【什么时间都有】'), true);
    expect(
      SystemScope(text.split('\n'), 'keyword').isSystem('【什么时间都有】'),
      false,
    );
  });

  test('聊天消息、书前标签与说明不算系统提示', () {
    const text =
        '【秦可：人呢？】\n【秦可：林夜你死了吗？】\n【秦可：照片.jpg】\n【轻小说+恋爱喜剧+日常】\n【8月10日，晴】\n【叠甲：本书为平行世界】\n【获得称号：夜猫子】\n';
    final scope = SystemScope(text.split('\n'));
    expect(bracketKind('【秦可：人呢？】', const {}), BracketKind.chat);
    expect(bracketKind('【秦可：照片.jpg】', {'秦可'}), BracketKind.chat);
    expect(bracketKind('【轻小说+恋爱喜剧+日常】', const {}), BracketKind.note);
    expect(bracketKind('【8月10日，晴】', const {}), BracketKind.note);
    expect(bracketKind('【叠甲：本书为平行世界】', const {}), BracketKind.note);
    expect(scope.isSystem('【秦可：照片.jpg】'), false);
    expect(scope.isSystem('【轻小说+恋爱喜剧+日常】'), false);
    expect(scope.isSystem('【获得称号：夜猫子】'), true);
  });
}
