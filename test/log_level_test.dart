import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/utils/log_level.dart';

void main() {
  test('benign Wintun adapter probe is downgraded to info', () {
    // Real line from the CLI: appears on every first connect while Wintun
    // creates the adapter — not an error, must not be counted/colored as one.
    const line =
        '[19:13:58] ❌ 18.07.2026 19:13:58.035382 ERROR [34676] WINTUN '
        'log_wintun: Failed to find matching adapter name: Element not found. '
        '(Code 0x00000490)';
    expect(isBenignCliNoise(line), isTrue);
    expect(logLevelOf(line), LogLevel.info);
  });

  test('real ERROR lines stay errors', () {
    expect(
      logLevelOf('2026-07-18 ERROR tunnel: connection refused'),
      LogLevel.error,
    );
    expect(logLevelOf('[12:00:00] ❌ Error: something broke'), LogLevel.error);
    expect(logLevelOf('[12:00:00] 🛑 Process exited with code: 1'),
        LogLevel.error);
  });

  test('warn and debug levels parse from raw CLI tokens', () {
    expect(logLevelOf('x WARN y'), LogLevel.warning);
    expect(logLevelOf('x DEBUG y'), LogLevel.debug);
    expect(logLevelOf('plain progress line'), LogLevel.info);
  });
}
