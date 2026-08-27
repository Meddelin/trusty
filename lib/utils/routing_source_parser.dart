import 'dart:convert';

/// Parser for the v2fly geosite source format
/// (github.com/v2fly/domain-list-community `data/<category>` files).
///
/// Only runs when a list is (re)downloaded — the routing-list cache stores
/// the flat parsed output, so the connect-time merge path never sees this
/// format (or its `include:` sub-fetches).

/// Maximum `include:` nesting; deeper chains are silently cut off.
const int geositeMaxIncludeDepth = 5;

/// URL of a sibling geosite category: same directory as [url], last path
/// segment replaced with [category] (`.../data/youtube` + `google` →
/// `.../data/google`).
String geositeSiblingUrl(String url, String category) =>
    url.substring(0, url.lastIndexOf('/') + 1) + category;

/// Parse a geosite category file into a flat de-duplicated domain list.
///
/// Line forms: bare domain = suffix match, `full:`/`domain:` prefixes are
/// stripped (exclusions have no exact-vs-suffix distinction), `include:cat`
/// pulls in another category via [fetchCategory] (bounded depth, cycles are
/// visited once), `regexp:`/`keyword:` rules cannot be expressed as
/// exclusions and are dropped. `@attribute` tails after whitespace are cut,
/// keeping the domain; comments (#) and blank lines are skipped.
Future<List<String>> parseGeositeList(
  String body, {
  required Future<String> Function(String category) fetchCategory,
}) async {
  final result = <String>[];
  final seen = <String>{};
  final visited = <String>{};

  Future<void> parse(String text, int depth) async {
    for (var line in const LineSplitter().convert(text)) {
      final comment = line.indexOf('#');
      if (comment >= 0) line = line.substring(0, comment);
      line = line.trim().toLowerCase();
      if (line.isEmpty) continue;
      final space = line.indexOf(RegExp(r'\s'));
      if (space >= 0) line = line.substring(0, space);
      if (line.startsWith('regexp:') || line.startsWith('keyword:')) continue;
      if (line.startsWith('include:')) {
        final category = line.substring('include:'.length);
        if (category.isEmpty || !visited.add(category)) continue;
        if (depth >= geositeMaxIncludeDepth) continue;
        // A failed sub-fetch propagates: better to fail the whole source (the
        // caller keeps the previous cache) than to save a silently gutted list.
        await parse(await fetchCategory(category), depth + 1);
        continue;
      }
      if (line.startsWith('full:')) {
        line = line.substring('full:'.length);
      } else if (line.startsWith('domain:')) {
        line = line.substring('domain:'.length);
      }
      if (line.isEmpty) continue;
      if (seen.add(line)) result.add(line);
    }
  }

  await parse(body, 0);
  return result;
}
