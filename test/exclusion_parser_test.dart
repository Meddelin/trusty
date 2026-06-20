import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/utils/exclusion_parser.dart';

void main() {
  test('splits on newlines, spaces and commas; dedups case-insensitively', () {
    final out = parseExclusionList(
      '92.255.112.0/20\nalfa.bank vk.com,ya.ru\nVK.COM\n\n  ',
    );
    expect(out, ['92.255.112.0/20', 'alfa.bank', 'vk.com', 'ya.ru']);
  });

  test('empty input yields empty list', () {
    expect(parseExclusionList('   \n  '), isEmpty);
  });
}
