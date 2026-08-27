/// Log severity derived from a rendered log line. The VPN service stores logs
/// as plain strings and severity travels in the text itself: the app's own
/// messages start with a level token (`ERROR `, `WARN `, `DEBUG `), while raw
/// CLI lines carry an inline " ERROR "/" WARN "/" DEBUG "/" TRACE " tag. This
/// parser reads both, so the Logs screen can color and filter by level and a
/// line pasted into a bug report still says what it was.
enum LogLevel { error, warning, info, debug }

/// Known-benign CLI lines that carry an ERROR tag but are normal operation.
/// Wintun probes for an existing adapter before creating one and logs the
/// miss as "ERROR ... Failed to find matching adapter name" — on every
/// first connect, with nothing actually wrong.
const List<String> _benignCliNoise = [
  'Failed to find matching adapter name',
];

bool isBenignCliNoise(String line) => _benignCliNoise.any(line.contains);

/// The level token the app puts in front of its own messages, either at the
/// very start of the string or straight after the `[HH:MM:SS]` stamp that
/// `VpnService._addLog` prepends when the line is stored.
final RegExp _leadingLevelToken =
    RegExp(r'^(?:\[\d{2}:\d{2}:\d{2}\]\s*)?(ERROR|WARN|DEBUG)\s');

LogLevel logLevelOf(String line) {
  if (isBenignCliNoise(line)) return LogLevel.info;

  final token = _leadingLevelToken.firstMatch(line)?.group(1);
  if (token == 'ERROR') return LogLevel.error;
  if (token == 'WARN') return LogLevel.warning;
  if (token == 'DEBUG') return LogLevel.debug;

  if (line.contains(' ERROR ')) return LogLevel.error;
  if (line.contains(' WARN ')) return LogLevel.warning;
  if (line.contains(' DEBUG ') || line.contains(' TRACE ')) {
    return LogLevel.debug;
  }
  return LogLevel.info;
}

/// Drops the leading level token from a message that is about to be drawn
/// next to a level column, so the console does not print "ERROR" twice. The
/// stored line keeps its token: that is what "Copy logs" hands to a bug
/// report. Anything without a leading token comes back untouched.
String withoutLevelToken(String message) =>
    message.replaceFirst(RegExp(r'^(?:ERROR|WARN|DEBUG)\s+'), '');
