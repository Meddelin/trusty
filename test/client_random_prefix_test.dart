import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/services/server_setup_service.dart';

void main() {
  test('generates a prefix/mask the client accepts (8hex/8hex, non-zero mask)', () {
    final re = RegExp(r'^[0-9a-f]{8}/[0-9a-f]{8}$');
    for (var i = 0; i < 200; i++) {
      final v = generateClientRandomPrefix(Random(i));
      expect(re.hasMatch(v), isTrue, reason: 'bad format: $v');
      // A bare prefix (no mask) is what the client ignores — never emit that.
      expect(v.contains('/'), isTrue);
      final mask = v.split('/')[1];
      expect(mask, isNot('00000000'), reason: 'mask must select some bits');
    }
  });
}
