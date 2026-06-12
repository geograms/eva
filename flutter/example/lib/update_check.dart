import 'dart:convert';

import 'package:http/http.dart' as http;

/// Release tag this APK was built from, baked in by CI via
/// `--dart-define=EVA_RELEASE_TAG=<tag>`. Empty for local/dev builds, which
/// disables the update check.
const String kBuiltReleaseTag = String.fromEnvironment('EVA_RELEASE_TAG');

const String kReleasesUrl =
    'https://github.com/geograms/eva/releases/latest';

/// Returns the tag of a newer published release, or null when up to date,
/// offline, or running a dev build. Never throws.
Future<String?> checkForNewerRelease() async {
  if (kBuiltReleaseTag.isEmpty) return null;
  try {
    final resp = await http.get(
      Uri.parse(
          'https://api.github.com/repos/geograms/eva/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final tag =
        (jsonDecode(resp.body) as Map<String, dynamic>)['tag_name'] as String?;
    if (tag == null || tag.isEmpty || tag == kBuiltReleaseTag) return null;
    return tag;
  } catch (_) {
    return null; // offline or rate-limited — silently skip
  }
}
