import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class CountingState extends PrototypeState {
  final listeners = <VoidCallback>{};
  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }
}

void main() {
  test('repeated history access keeps listener ownership bounded', () {
    final backend = CountingState();
    final library = LegacyLibraryAdapter(backend: backend);
    final baseCount = backend.listeners.length;
    for (var i = 0; i < 100; i++) {
      final history = library.openChangeHistory();
      expect(history.records('missing-book'), isEmpty);
      backend.change(() {});
    }
    expect(backend.listeners.length, lessThanOrEqualTo(baseCount + 1));
    library.dispose();
    expect(backend.listeners, isEmpty);
    backend.change(() {});
    backend.dispose();
  });
}
