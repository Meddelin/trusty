import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/screens/split_tunnel_screen.dart';

void main() {
  group('extractDomainSuggestions', () {
    test('extracts new domains from log lines', () {
      final result = extractDomainSuggestions(
        ['DNS query for example.com resolved', 'connecting to api.github.com'],
        existingDomains: <String>{},
        existingSuggestions: <String>[],
        remainingSlots: 20,
      );
      expect(result, containsAll(<String>['example.com', 'api.github.com']));
    });

    test('skips domains already in the current set (case-insensitive)', () {
      final result = extractDomainSuggestions(
        ['hit Example.COM again'],
        existingDomains: <String>{'example.com'},
        existingSuggestions: <String>[],
        remainingSlots: 20,
      );
      expect(result, isEmpty);
    });

    test('skips already-suggested and de-duplicates within a batch', () {
      final result = extractDomainSuggestions(
        ['a.com a.com', 'b.com'],
        existingDomains: <String>{},
        existingSuggestions: <String>['b.com'],
        remainingSlots: 20,
      );
      expect(result, <String>['a.com']);
    });

    test('filters .local, .internal and trusttunnel.com', () {
      final result = extractDomainSuggestions(
        ['printer.local mail.internal trusttunnel.com keep.me'],
        existingDomains: <String>{},
        existingSuggestions: <String>[],
        remainingSlots: 20,
      );
      expect(result, <String>['keep.me']);
    });

    test('honours remainingSlots cap and returns empty when none left', () {
      final capped = extractDomainSuggestions(
        ['a.com b.com c.com'],
        existingDomains: <String>{},
        existingSuggestions: <String>[],
        remainingSlots: 2,
      );
      expect(capped.length, 2);

      final none = extractDomainSuggestions(
        ['a.com'],
        existingDomains: <String>{},
        existingSuggestions: <String>[],
        remainingSlots: 0,
      );
      expect(none, isEmpty);
    });
  });
}
