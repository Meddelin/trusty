import 'dart:io';

/// Parse a free-text block of domains / IPs / CIDR ranges into a clean,
/// de-duplicated list. Accepts entries separated by newlines, spaces, tabs or
/// commas — so a user can paste a whole list at once instead of adding each
/// line by hand. De-duplication is case-insensitive; original casing is kept.
List<String> parseExclusionList(String raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final token in raw.split(RegExp(r'[\s,]+'))) {
    final t = token.trim();
    if (t.isEmpty) continue;
    if (seen.add(t.toLowerCase())) result.add(t);
  }
  return result;
}

/// Bulk-import a pasted block of exclusions: tokens from
/// [parseExclusionList] are normalized via [normalizeExclusion]; invalid
/// tokens are counted, entries already in [existing] (lowercase) or seen
/// earlier in the paste are skipped. Set-based lookups keep multi-thousand
/// -line pastes linear.
(List<String>, int) importExclusionList(String raw, Set<String> existing) {
  final added = <String>[];
  final seen = <String>{};
  var invalid = 0;
  for (final token in parseExclusionList(raw)) {
    final entry = normalizeExclusion(token);
    if (entry == null) {
      invalid++;
    } else if (!existing.contains(entry) && seen.add(entry)) {
      added.add(entry);
    }
  }
  return (added, invalid);
}

/// Kind of a split-tunnel exclusion entry.
enum ExclusionKind { domain, ip, cidr, invalid }

/// One hostname label: unicode letters/digits, hyphens inside.
final _labelRe = RegExp(
  r'^[\p{L}\p{N}]([\p{L}\p{N}-]*[\p{L}\p{N}])?$',
  unicode: true,
);

bool _isHostname(String host, {required bool requireDot}) {
  if (host.isEmpty) return false;
  final labels = host.split('.');
  if (requireDot && labels.length < 2) return false;
  if (!labels.every(_labelRe.hasMatch)) return false;
  // Real TLDs never start with a digit — this catches malformed IPs like
  // "1.2.3.4abc" that would otherwise pass the per-label check.
  return RegExp(r'^\p{L}', unicode: true).hasMatch(labels.last);
}

/// Classify a (already trimmed/normalized) exclusion entry.
/// Domains may carry a single leading `*.` wildcard; IPv4/IPv6 are detected
/// via [InternetAddress.tryParse]; CIDR prefixes are range-checked.
ExclusionKind classifyExclusion(String entry) {
  if (entry.isEmpty) return ExclusionKind.invalid;
  final slash = entry.indexOf('/');
  if (slash >= 0) {
    final ip = InternetAddress.tryParse(entry.substring(0, slash));
    final prefix = int.tryParse(entry.substring(slash + 1));
    if (ip == null || prefix == null || prefix < 0) return ExclusionKind.invalid;
    final maxPrefix = ip.type == InternetAddressType.IPv6 ? 128 : 32;
    return prefix <= maxPrefix ? ExclusionKind.cidr : ExclusionKind.invalid;
  }
  if (InternetAddress.tryParse(entry) != null) return ExclusionKind.ip;
  final host = entry.startsWith('*.') ? entry.substring(2) : entry;
  // Bare wildcard hosts (`*.local`) may be a single label; plain hostnames
  // need at least two ("vk.com"), which also keeps obvious typos out.
  return _isHostname(host, requireDot: !entry.startsWith('*.'))
      ? ExclusionKind.domain
      : ExclusionKind.invalid;
}

/// Normalize free-form user input into a clean exclusion entry:
/// strips URL scheme, path/query/fragment, userinfo, port, brackets and the
/// trailing dot; lowercases. Returns null when the result is not a valid
/// domain, IP or CIDR — so pasting "https://user@VK.com:443/feed" yields
/// "vk.com" and garbage yields null instead of landing in the config.
String? normalizeExclusion(String raw) {
  var s = raw.trim().replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  if (s.isEmpty) return null;

  // CIDR intent ("ip/digits"): validate strictly instead of path-cutting,
  // so a typo like 10.0.0.0/99 is rejected — not silently truncated to a
  // single-host entry. A URL with an IP host (1.2.3.4/path) still falls
  // through to the path-cutting below.
  final asTyped = s.toLowerCase();
  final slash = s.indexOf('/');
  if (slash > 0 &&
      InternetAddress.tryParse(s.substring(0, slash)) != null &&
      RegExp(r'^\d+$').hasMatch(s.substring(slash + 1))) {
    return classifyExclusion(asTyped) == ExclusionKind.cidr ? asTyped : null;
  }

  // Cut path/query/fragment, then userinfo.
  final cut = s.indexOf(RegExp(r'[/?#]'));
  if (cut >= 0) s = s.substring(0, cut);
  final at = s.lastIndexOf('@');
  if (at >= 0) s = s.substring(at + 1);

  // Strip port: bracketed IPv6 first ([2001:db8::1]:443), then host:port —
  // but never split a bare IPv6 address on its colons.
  final bracket = RegExp(r'^\[(.+)\](:\d+)?$').firstMatch(s);
  if (bracket != null) {
    s = bracket.group(1)!;
  } else if (InternetAddress.tryParse(s) == null) {
    final port = RegExp(r'^(.+):(\d+)$').firstMatch(s);
    if (port != null) s = port.group(1)!;
  }

  while (s.endsWith('.')) {
    s = s.substring(0, s.length - 1);
  }
  s = s.toLowerCase();

  return classifyExclusion(s) == ExclusionKind.invalid ? null : s;
}
