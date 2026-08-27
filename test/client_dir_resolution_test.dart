import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:trusty/services/config_service.dart';

void main() {
  group('resolveClientBaseDir', () {
    String resolve(
      Set<String> existingFiles,
      String exeDir,
      String cwd, {
      bool devRun = false,
    }) => ConfigService.resolveClientBaseDir(
      exeDir: exeDir,
      currentDir: cwd,
      fileExists: existingFiles.contains,
      devRun: devRun,
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
        {
          p.join(r'C:\apps\Trusty', 'client', 'leftover.lst'),
          p.join(r'C:\repo\trusty', 'client', 'trusttunnel_client.exe'),
        },
        r'C:\apps\Trusty',
        r'C:\repo\trusty',
      );
      expect(result, r'C:\repo\trusty');
    });

    test('points next to the exe when neither location has the CLI yet', () {
      // The first-run case. The answer is the path the user is told to fill and
      // the path client/ is created in, so it must never be the launch CWD.
      final result = resolve(
        {},
        r'C:\apps\Trusty',
        r'C:\Users\someone\unrelated',
      );
      expect(result, r'C:\apps\Trusty');
    });

    test('a dev run still bases itself on the launch directory', () {
      // `flutter run` and the test harness both live here: the executable is
      // the tester or a debug runner inside build/, so the CWD is the project.
      final result = resolve(
        {},
        r'C:\flutter\bin\cache\artifacts\engine\windows-x64',
        r'C:\repo\trusty',
        devRun: true,
      );
      expect(result, r'C:\repo\trusty');
    });

    test('ignores a launch CWD that is itself named client/', () {
      // Reported in the wild: launched with a CWD ending in \client, the old
      // rule produced ...\client\client and created it in an unrelated project.
      final result = resolve(
        {},
        r'C:\apps\Trusty',
        r'C:\other\project\bundle\nsis\client',
      );
      expect(result, r'C:\apps\Trusty');
    });
  });
}
