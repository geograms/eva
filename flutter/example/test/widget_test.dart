// Basic smoke test: the root app widget constructs.
//
// The full app (ChatScreen) loads the inference engine over platform channels
// in initState, which isn't available in the unit-test host — so we verify the
// root widget builds as a Widget rather than pumping the whole tree.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eva/main.dart';

void main() {
  test('EvaApp can be constructed', () {
    expect(const EvaApp(), isA<Widget>());
  });
}
