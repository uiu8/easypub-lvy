import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// V104：生产入口用默认配置按名称加载桥接库（测试一律按路径加载，测不到这一点）。
/// 重新生成桥接代码时若读不到 crate 名，名称会变成 UNKNOWN，软件打不开。
void main() {
  test('桥接库默认按 easypub_bridge 加载', () {
    expect(RustLib.kDefaultExternalLibraryLoaderConfig.stem, 'easypub_bridge');
  });
}
