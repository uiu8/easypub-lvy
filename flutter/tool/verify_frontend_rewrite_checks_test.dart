// Compatibility entrypoint for the current check-hub integration regression.
// The pre-completion page labels and breadcrumb assertions are obsolete.
import '../test/completion/check_hub_native_test.dart' as current;

void main() => current.main();
