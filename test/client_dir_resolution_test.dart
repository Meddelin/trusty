import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:trusty/services/config_service.dart';

void main() {
  group('resolveClientBaseDir', () {
    String resolve(Set<String> existingFiles, String exeDir, String cwd) =>
        ConfigService.resolveClientBaseDir(
          exeDir: exeDir,
          currentDir: cwd,
          fileExists: existingFiles.contains,
        );

    test('prefers the exe dir when the CLI is installed there, any CWD', () {
      final result = resolve(
        {p.join(r'C:\apps\Trusty', 'client', 'trusttunnel_client.exe')},
        r'C:\apps\Trusty',
        r'C:\somewhere\else',
      );
      expect(result, r'C:\apps\Trusty');
    });

    test('recognizes the legacy binary name next to the exe', () {
      final result = resolve(
        {p.join(r'C:\apps\Trusty', 'client', 'trusttunnel.exe')},
        r'C:\apps\Trusty',
        r'C:\somewhere\else',
      );
      expect(result, r'C:\apps\Trusty');
    });

    test('falls back to CWD for dev runs when the exe dir has no CLI', () {
      final result = resolve(
        {p.join(r'C:\repo\trusty', 'client', 'trusttunnel_client.exe')},
        r'C:\repo\trusty\build\windows\x64\runner\Debug',
        r'C:\repo\trusty',
      );
      expect(result, r'C:\repo\trusty');
    });

    test('a stray client/ dir without a CLI does not hijack the lookup', () {
      final result = resolve(
        {p.join(r'C:\apps\Trusty', 'client', 'leftover.lst')},
        r'C:\apps\Trusty',
        r'C:\repo\trusty',
      );
      expect(result, r'C:\repo\trusty');
    });

    test('defaults to CWD when neither location has the CLI yet', () {
      final result = resolve(
        {},
        r'C:\apps\Trusty',
        r'C:\Users\someone\unrelated',
      );
      expect(result, r'C:\Users\someone\unrelated');
    });
  });
}
