import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_prefs.dart';

/// Release tag this APK was built from, baked in by CI via
/// `--dart-define=EVA_RELEASE_TAG=<tag>`. Empty for local/dev builds, which
/// disables the update check.
const String kBuiltReleaseTag = String.fromEnvironment('EVA_RELEASE_TAG');

const String kReleasesUrl =
    'https://github.com/geograms/eva/releases/latest';

/// File name of the installable arm64 APK attached to each release (and its
/// checksum companion), produced by the CI release workflow.
const String kApkAssetName = 'eva-android-arm64-v8a.apk';

/// A published release with the bits the updater needs to download + install it.
class ReleaseInfo {
  ReleaseInfo({required this.tag, required this.apkUrl, this.sha256Url});

  /// Release tag (e.g. "v2.6").
  final String tag;

  /// Direct download URL of the arm64 APK asset.
  final String apkUrl;

  /// Direct download URL of the APK's `.sha256` checksum file, if present.
  final String? sha256Url;

  /// Whether this release is newer than the running build (and we know our own
  /// build tag — dev builds can't compare, so this is false there).
  bool get isNewer => kBuiltReleaseTag.isNotEmpty && tag != kBuiltReleaseTag;
}

/// Returns the tag of a newer published release, or null when up to date,
/// offline, or running a dev build. Never throws. Used by the lightweight
/// in-chat update banner.
Future<String?> checkForNewerRelease() async {
  if (kBuiltReleaseTag.isEmpty) return null;
  final info = await fetchLatestRelease();
  return (info != null && info.isNewer) ? info.tag : null;
}

/// Fetches the latest release from the configured update URL and resolves its
/// APK + checksum asset URLs. Returns null when offline, rate-limited, or the
/// release has no installable APK asset. Never throws.
Future<ReleaseInfo?> fetchLatestRelease({String? apiUrl}) async {
  final url = apiUrl ?? await loadUpdateUrl();
  try {
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'Eva-Updater',
      },
    ).timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final tag = (json['tag_name'] as String?)?.trim();
    if (tag == null || tag.isEmpty) return null;

    String? apkUrl;
    String? shaUrl;
    final assets = json['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = (a['name'] as String?) ?? '';
        final dl = a['browser_download_url'] as String?;
        if (dl == null) continue;
        if (name == kApkAssetName) {
          apkUrl = dl;
        } else if (name == '$kApkAssetName.sha256') {
          shaUrl = dl;
        }
      }
    }
    // Fall back to the stable "latest download" URLs if the asset list didn't
    // resolve (e.g. a custom endpoint that omits browser_download_url).
    apkUrl ??= '$kReleasesUrl/download/$kApkAssetName';
    shaUrl ??= '$kReleasesUrl/download/$kApkAssetName.sha256';
    return ReleaseInfo(tag: tag, apkUrl: apkUrl, sha256Url: shaUrl);
  } catch (_) {
    return null; // offline or rate-limited — silently skip
  }
}
