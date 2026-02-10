import 'dart:io';
import 'dart:convert';

/// Result of domain discovery
class DomainDiscoveryResult {
  final List<String> discoveredDomains;
  final String? error;

  DomainDiscoveryResult({
    required this.discoveredDomains,
    this.error,
  });
}

/// Service for discovering related domains by fetching and parsing HTML
class DomainDiscoveryService {
  static const int _timeoutSeconds = 10;
  static const int _maxBodyBytes = 512 * 1024; // 512KB

  // Domains to ignore (tracking, analytics, common infrastructure, ads)
  static const _ignoredDomains = <String>{
    // Standards/specs
    'w3.org',
    'schema.org',
    'xmlns.com',
    'purl.org',
    'ogp.me',
    'creativecommons.org',
    // Analytics & tracking
    'google-analytics.com',
    'googletagmanager.com',
    'doubleclick.net',
    'facebook.com',
    'facebook.net',
    'twitter.com',
    'x.com',
    'linkedin.com',
    'reddit.com',
    'pinterest.com',
    'instagram.com',
    // Ads
    'googlesyndication.com',
    'googleadservices.com',
    'adroll.com',
    'taboola.com',
    'outbrain.com',
    // CDNs (common)
    'cloudflare.com',
    'cloudflareinsights.com',
    'akamaihd.net',
    'fastly.net',
    // Fonts
    'fonts.googleapis.com',
    'fonts.gstatic.com',
    'typekit.net',
  };

  /// Fetch a domain's page and extract related external domains
  Future<DomainDiscoveryResult> discoverRelatedDomains(String domain) async {
    try {
      final html = await _fetchPage(domain);
      if (html == null) {
        return DomainDiscoveryResult(
          discoveredDomains: [],
          error: 'Failed to load page',
        );
      }

      final rootDomain = _extractRootDomain(domain);
      final discovered = _extractAllRelatedDomains(html, rootDomain ?? domain);

      final sorted = discovered.toList()..sort();
      return DomainDiscoveryResult(discoveredDomains: sorted);
    } catch (e) {
      return DomainDiscoveryResult(
        discoveredDomains: [],
        error: e.toString(),
      );
    }
  }

  Future<String?> _fetchPage(String domain) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: _timeoutSeconds)
      ..badCertificateCallback = (cert, host, port) => true; // ignore cert errors for discovery

    try {
      final uri = Uri.parse('https://$domain');
      final request = await client.getUrl(uri)
          .timeout(const Duration(seconds: _timeoutSeconds));
      request.followRedirects = true;
      request.maxRedirects = 3;
      request.headers.set('User-Agent', 'Mozilla/5.0');

      final response = await request.close()
          .timeout(const Duration(seconds: _timeoutSeconds));

      // Check content type
      final contentType = response.headers.contentType;
      if (contentType != null &&
          contentType.primaryType != 'text') {
        return null;
      }

      // Read body with size limit
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBodyBytes) break;
      }

      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Extract URLs from src= and href= attributes in HTML, plus domains from JS code
  List<String> _extractUrls(String html) {
    final urls = <String>{};

    // 1. Extract from src= and href= attributes
    final attrPattern = RegExp(
      r'''(?:src|href)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final match in attrPattern.allMatches(html)) {
      final url = match.group(1)!;
      if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('//')) {
        urls.add(url);
      }
    }

    // 2. Extract URLs from JavaScript strings (various formats)
    // Matches: "https://domain.com", 'https://domain.com', `https://domain.com`
    final jsUrlPattern = RegExp(
      r'''["'`](https?://[^"'`\s]+)["'`]''',
      caseSensitive: false,
    );
    for (final match in jsUrlPattern.allMatches(html)) {
      urls.add(match.group(1)!);
    }

    // 3. Extract protocol-relative URLs from JS
    final protocolRelativePattern = RegExp(
      r'''["'`](//[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}[^"'`\s]*)["'`]''',
    );
    for (final match in protocolRelativePattern.allMatches(html)) {
      urls.add(match.group(1)!);
    }

    // 4. Extract bare domain patterns from JS code
    // Matches patterns like: domain.com, subdomain.domain.com in various contexts
    final domainPattern = RegExp(
      r'''(?:["'`:/]|^)([a-zA-Z0-9][-a-zA-Z0-9]{0,62}(?:\.[a-zA-Z0-9][-a-zA-Z0-9]{0,62})+\.[a-zA-Z]{2,})(?:["'`:/\s]|$)''',
    );
    for (final match in domainPattern.allMatches(html)) {
      final domain = match.group(1)!;
      // Convert bare domain to URL for consistency
      if (!urls.any((url) => url.contains(domain))) {
        urls.add('https://$domain');
      }
    }

    // 5. Extract from fetch(), XMLHttpRequest, axios calls
    final fetchPattern = RegExp(
      r'''(?:fetch|axios(?:\.[a-z]+)?|XMLHttpRequest)\s*\(\s*["'`]([^"'`]+)["'`]''',
      caseSensitive: false,
    );
    for (final match in fetchPattern.allMatches(html)) {
      final url = match.group(1)!;
      if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('//')) {
        urls.add(url);
      }
    }

    return urls.toList();
  }

  /// Extract hostname from a URL string
  String? _extractHostFromUrl(String url) {
    try {
      var normalized = url;
      if (normalized.startsWith('//')) {
        normalized = 'https:$normalized';
      }
      return Uri.parse(normalized).host.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /// Extract root domain from a hostname (e.g. cdn.example.com -> example.com)
  /// Also handles complex subdomains (e.g. dpm-io-l44.dpm.lol -> dpm.lol)
  String? _extractRootDomain(String host) {
    final parts = host.split('.');
    if (parts.length < 2) return null;

    // Handle common two-part TLDs
    const twoPartTlds = {
      'co.uk', 'co.jp', 'co.kr', 'co.nz', 'co.za',
      'com.au', 'com.br', 'com.cn', 'com.tw', 'com.ua',
      'org.uk', 'net.au', 'ac.uk',
    };

    if (parts.length >= 3) {
      final lastTwo = '${parts[parts.length - 2]}.${parts.last}';
      if (twoPartTlds.contains(lastTwo)) {
        if (parts.length >= 4) {
          return '${parts[parts.length - 3]}.$lastTwo';
        }
        return host;
      }
    }

    // For subdomains, return the root domain (last two parts)
    if (parts.length >= 2) {
      return '${parts[parts.length - 2]}.${parts.last}';
    }

    return host;
  }

  /// Get all subdomains from HTML (for comprehensive discovery)
  /// Returns both root domains and their subdomains for better grouping
  Set<String> _extractAllRelatedDomains(String html, String rootDomain) {
    final urls = _extractUrls(html);
    final domains = <String>{};

    for (final url in urls) {
      final host = _extractHostFromUrl(url);
      if (host == null) continue;

      final root = _extractRootDomain(host);
      if (root == null || root == rootDomain) continue;
      if (_ignoredDomains.contains(root)) continue;

      // Add both the root domain AND specific subdomains for better discovery
      domains.add(root);

      // If it's a subdomain, also add it separately (e.g., cdn.example.com)
      if (host != root && host.endsWith('.$root')) {
        domains.add(host);
      }
    }

    return domains;
  }
}
