/// Log severity derived from a rendered log line. The VPN service stores
/// logs as plain strings (app messages carry emoji markers, raw CLI lines
/// carry " ERROR "/" WARN " level tokens) — this parser unifies both so the
/// Logs screen can color and filter by level instead of sniffing a handful
/// of emojis.
enum LogLevel { error, warning, info, debug }

/// Known-benign CLI lines that carry an ERROR tag but are normal operation.
/// Wintun probes for an existing adapter before creating one and logs the
/// miss as "ERROR ... Failed to find matching adapter name" — on every
/// first connect, with nothing actually wrong.
const List<String> _benignCliNoise = [
  'Failed to find matching adapter name',
];

bool isBenignCliNoise(String line) => _benignCliNoise.any(line.contains);

LogLevel logLevelOf(String line) {
  if (isBenignCliNoise(line)) return LogLevel.info;
  if (line.contains('❌') || line.contains('🛑') || line.contains(' ERROR ')) {
    return LogLevel.error;
  }
  if (line.contains('⚠️') || line.contains(' WARN ')) {
    return LogLevel.warning;
  }
  if (line.contains('🔍') ||
      line.contains(' DEBUG ') ||
      line.contains(' TRACE ')) {
    return LogLevel.debug;
  }
  return LogLevel.info;
}
