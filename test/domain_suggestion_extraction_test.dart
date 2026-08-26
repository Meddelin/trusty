import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/screens/split_tunnel_screen.dart';

void main() {
  appDiscoveryHelperTests();
  domainSuggestionTests();
}

void appDiscoveryHelperTests() {
  test('storeAppDisplayName drops publisher and splits camel case', () {
    expect(storeAppDisplayName('AppleInc.AppleMusicWin'), 'Apple Music Win');
    // Compound brand names split imperfectly — acceptable, since app search
    // is space-insensitive (query "whatsapp" still matches).
    expect(storeAppDisplayName('5319275A.WhatsAppDesktop'), 'Whats App Desktop');
    expect(storeAppDisplayName('SpotifyAB.SpotifyMusic'), 'Spotify Music');
    expect(storeAppDisplayName('NoDotName'), 'No Dot Name');
  });

  test('manifestExecutables collects all Application nodes, skips tokens', () {
    const xml = '<Application Executable="Helper\\ShareTarget.exe"/>'
        '<Application Executable="app/Main.exe"/>'
        '<Application Executable="MAIN.EXE"/>'
        r'<Application Executable="$targetnametoken$.exe"/>';
    expect(
      manifestExecutables(xml),
      ['ShareTarget.exe', 'Main.exe'],
    );
  });

  test('registryIconExePath parses DisplayIcon variants', () {
    expect(registryIconExePath(r'"C:\P\app.exe",0'), r'C:\P\app.exe');
    expect(registryIconExePath(r'C:\P\app.exe,1'), r'C:\P\app.exe');
    expect(registryIconExePath(r'C:\P\app.exe'), r'C:\P\app.exe');
    expect(registryIconExePath(r'C:\P\app.ico'), isNull);
    expect(registryIconExePath(r'C:\P\app.ico,0'), isNull);
    expect(registryIconExePath(''), isNull);
    expect(registryIconExePath(null), isNull);
  });

  test('iconCacheName is deterministic and file-safe', () {
    final a = iconCacheName(r'C:\Program Files\App\app.exe');
    expect(a, iconCacheName(r'C:\Program Files\App\app.exe'));
    expect(RegExp(r'^[a-z0-9_]+\.png$').hasMatch(a), isTrue);
    expect(a, isNot(iconCacheName(r'C:\Other\app.exe')));
  });

  test('tasklistProcessName parses csv lines and rejects garbage', () {
    expect(
      tasklistProcessName('"AppleMusic.exe","1234","Console","1","150 000 K"'),
      'AppleMusic.exe',
    );
    expect(tasklistProcessName('INFO: no tasks'), isNull);
  });
}

void domainSuggestionTests() {
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
