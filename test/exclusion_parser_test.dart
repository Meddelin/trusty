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

  group('classifyExclusion', () {
    test('recognizes domains, IPs and CIDR', () {
      expect(classifyExclusion('vk.com'), ExclusionKind.domain);
      expect(classifyExclusion('sub.domain.co.uk'), ExclusionKind.domain);
      expect(classifyExclusion('*.local'), ExclusionKind.domain);
      expect(classifyExclusion('кино.рф'), ExclusionKind.domain);
      expect(classifyExclusion('8.8.8.8'), ExclusionKind.ip);
      expect(classifyExclusion('2001:db8::1'), ExclusionKind.ip);
      expect(classifyExclusion('10.0.0.0/8'), ExclusionKind.cidr);
      expect(classifyExclusion('2001:db8::/32'), ExclusionKind.cidr);
    });

    test('rejects garbage', () {
      expect(classifyExclusion(''), ExclusionKind.invalid);
      expect(classifyExclusion('not a domain'), ExclusionKind.invalid);
      expect(classifyExclusion('nodots'), ExclusionKind.invalid);
      expect(classifyExclusion('1.2.3.4abc'), ExclusionKind.invalid);
      expect(classifyExclusion('10.0.0.0/33'), ExclusionKind.invalid);
      expect(classifyExclusion('vk..com'), ExclusionKind.invalid);
      expect(classifyExclusion('-bad.com'), ExclusionKind.invalid);
    });
  });

  group('normalizeExclusion', () {
    test('strips URL parts down to the host', () {
      expect(normalizeExclusion('https://VK.com/feed?w=wall'), 'vk.com');
      expect(normalizeExclusion('http://user@site.io:8080/x#y'), 'site.io');
      expect(normalizeExclusion('  youtube.com.  '), 'youtube.com');
    });

    test('strips ports from IPs, keeps bare IPv6 intact', () {
      expect(normalizeExclusion('1.2.3.4:8080'), '1.2.3.4');
      expect(normalizeExclusion('[2001:db8::1]:443'), '2001:db8::1');
      expect(normalizeExclusion('2001:db8::1'), '2001:db8::1');
    });

    test('keeps CIDR and wildcards as-is', () {
      expect(normalizeExclusion('92.255.112.0/20'), '92.255.112.0/20');
      expect(normalizeExclusion('*.Company.Internal'), '*.company.internal');
    });

    test('returns null for invalid input', () {
      expect(normalizeExclusion('not a domain'), isNull);
      expect(normalizeExclusion('https://'), isNull);
      expect(normalizeExclusion('10.0.0.0/99'), isNull);
      expect(normalizeExclusion(''), isNull);
    });
  });
}
