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
