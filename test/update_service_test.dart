import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/services/update_service.dart';

void main() {
  test('isNewerVersion compares x.y.z, ignoring build/pre-release suffixes', () {
    expect(isNewerVersion('0.3.1', '0.3.0'), isTrue);
    expect(isNewerVersion('0.4.0', '0.3.9'), isTrue);
    expect(isNewerVersion('1.0.0', '0.9.9'), isTrue);
    expect(isNewerVersion('0.3.0', '0.3.0'), isFalse);
    expect(isNewerVersion('0.2.9', '0.3.0'), isFalse);
    expect(isNewerVersion('0.3.0', '0.3.0+1'), isFalse);
    expect(isNewerVersion('0.3.1-rc1', '0.3.0'), isTrue);
    expect(isNewerVersion('', '0.3.0'), isFalse);
    expect(isNewerVersion('garbage', '0.3.0'), isFalse);
  });
}
