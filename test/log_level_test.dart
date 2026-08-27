import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/utils/log_level.dart';

void main() {
  test('benign Wintun adapter probe is downgraded to info', () {
    // Real line from the CLI: appears on every first connect while Wintun
    // creates the adapter — not an error, must not be counted/colored as one.
    const line =
        '[19:13:58] 18.07.2026 19:13:58.035382 ERROR [34676] WINTUN '
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
    expect(
      logLevelOf('[12:00:00] ERROR Error: something broke'),
      LogLevel.error,
    );
    expect(
      logLevelOf('[12:00:00] ERROR Process exited with code: 1'),
      LogLevel.error,
    );
  });

  test('warn and debug levels parse from raw CLI tokens', () {
    expect(logLevelOf('x WARN y'), LogLevel.warning);
    expect(logLevelOf('x DEBUG y'), LogLevel.debug);
    expect(logLevelOf('x TRACE y'), LogLevel.debug);
    expect(logLevelOf('plain progress line'), LogLevel.info);
  });

  group('leading level token', () {
    // The app's own messages carry their severity as the first word, so it
    // survives a copy-paste into a bug report. Both the bare message and the
    // stored `[HH:MM:SS] message` form must classify the same.
    test('classifies a bare message', () {
      expect(logLevelOf('ERROR Error during disconnect: broken pipe'),
          LogLevel.error);
      expect(logLevelOf('WARN Already connected or connecting'),
          LogLevel.warning);
      expect(logLevelOf('DEBUG upstream negotiated http2'), LogLevel.debug);
    });

    test('classifies the same message once _addLog has stamped it', () {
      expect(logLevelOf('[12:00:00] ERROR Error: something broke'),
          LogLevel.error);
      expect(logLevelOf('[12:00:00] WARN Failed to terminate process: 5'),
          LogLevel.warning);
      expect(logLevelOf('[12:00:00] DEBUG upstream negotiated http2'),
          LogLevel.debug);
    });

    test('an untokened message is info', () {
      expect(logLevelOf('[12:00:00] Connected successfully!'), LogLevel.info);
      expect(logLevelOf('[12:00:00] Starting Trusty client...'), LogLevel.info);
    });

    test('the token has to lead, and has to be a whole word', () {
      // A sentence that merely mentions the word is not an error line.
      expect(logLevelOf('[12:00:00] Retrying after the last ERRORed attempt'),
          LogLevel.info);
      expect(logLevelOf('[12:00:00] WARNING: this is prose'), LogLevel.info);
    });
  });

  group('withoutLevelToken', () {
    test('drops the token the level column already shows', () {
      expect(withoutLevelToken('ERROR Error: something broke'),
          'Error: something broke');
      expect(withoutLevelToken('WARN Already connected or connecting'),
          'Already connected or connecting');
      expect(withoutLevelToken('DEBUG upstream negotiated http2'),
          'upstream negotiated http2');
    });

    test('leaves everything else alone', () {
      expect(withoutLevelToken('Connected successfully!'),
          'Connected successfully!');
      expect(
        withoutLevelToken('2026-07-18 ERROR tunnel: connection refused'),
        '2026-07-18 ERROR tunnel: connection refused',
      );
      expect(withoutLevelToken('ERRORed once'), 'ERRORed once');
    });

    test('only the leading token goes', () {
      expect(withoutLevelToken('ERROR ERROR twice'), 'ERROR twice');
    });
  });
}
