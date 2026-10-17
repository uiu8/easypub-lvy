import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await const FlutterRustBridgeNativeAssetsBuilder(
      cratePath: '../rust/crates/easypub_bridge',
      // Flutter sanitizes the hook process environment. Keep Cargo and the
      // host compiler in the project SDK; the global Rust host can be GNU.
      extraCargoEnvironmentVariables: {
        'RUSTUP_HOME': 'D:/software/EasyPub-Toolchains/rustup',
        'CARGO_HOME': 'D:/software/EasyPub-Toolchains/cargo',
      },
    ).run(input: input, output: output);
  });
}
