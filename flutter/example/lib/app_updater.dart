import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_prefs.dart';
import 'download_service.dart';
import 'update_check.dart';

/// Where the updater is in its lifecycle (drives the Updates panel UI).
enum UpdateStatus {
  idle, // nothing checked yet
  checking, // querying the release API
  upToDate, // newest release == running build
  available, // a newer release is published, not yet downloaded
  downloading, // fetching the APK (see [AppUpdater.progress])
  verifying, // checking the downloaded APK's sha256
  readyToInstall, // verified; handing off to the system installer
  installing, // system installer launched
  error, // see [AppUpdater.error]
}

/// Coordinates the in-app update: checks the configured release API, downloads
/// the APK (held alive by the foreground service so it survives backgrounding),
/// verifies its checksum, and launches the system package installer. The
/// install itself always shows the OS confirmation — Android does not allow a
/// non-system app to install silently.
///
/// Singleton so the chat screen, the Settings panel, and the auto-update path
/// all share one state. Android-only; on other platforms it stays [idle].
class AppUpdater extends ChangeNotifier {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  static const MethodChannel _channel = MethodChannel('eva/installer');

  UpdateStatus _status = UpdateStatus.idle;
  double? _progress; // 0..1 while downloading (null = indeterminate)
  ReleaseInfo? _latest;
  String? _error;
  bool _canInstall = true; // "Install unknown apps" granted for Eva
  bool _busy = false; // a download/install flow is running
  bool _cancel = false;

  UpdateStatus get status => _status;
  double? get progress => _progress;
  ReleaseInfo? get latest => _latest;
  String? get error => _error;
  bool get canInstall => _canInstall;
  bool get busy => _busy;

  /// The tag this build was made from (empty on dev builds → updates disabled).
  String get currentTag => kBuiltReleaseTag;
  bool get isDevBuild => kBuiltReleaseTag.isEmpty;

  /// Whether a newer release is known to be available.
  bool get updateAvailable => _latest?.isNewer ?? false;

  void _set(UpdateStatus s, {double? progress, String? error}) {
    _status = s;
    _progress = progress;
    _error = error;
    notifyListeners();
  }

  /// Refreshes whether Eva is allowed to install APKs.
  Future<void> refreshPermission() async {
    if (!Platform.isAndroid) return;
    try {
      _canInstall = await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      _canInstall = false;
    }
    notifyListeners();
  }

  /// Opens the system "Install unknown apps" screen for Eva.
  Future<void> requestInstallPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestInstallPermission');
    } catch (_) {}
  }

  /// Queries the release API for the latest version. Safe to call repeatedly.
  Future<void> check() async {
    if (!Platform.isAndroid || _busy) return;
    _set(UpdateStatus.checking);
    await refreshPermission();
    final info = await fetchLatestRelease();
    _latest = info;
    if (info == null) {
      _set(UpdateStatus.error, error: 'Could not reach the update server.');
      return;
    }
    _set(info.isNewer ? UpdateStatus.available : UpdateStatus.upToDate);
  }

  /// Auto-update entry point (called on launch): if enabled and an update is
  /// both available and permitted, download + launch the installer. If the
  /// permission is missing, it stops at [available] so the UI can prompt.
  Future<void> maybeAutoUpdate() async {
    if (!Platform.isAndroid || isDevBuild) return;
    if (!await loadAutoUpdate()) return;
    await check();
    if (updateAvailable && _canInstall) {
      await downloadAndInstall();
    }
  }

  /// Downloads the latest APK and launches the installer. Ensures a release is
  /// known (checks first if needed) and that install permission is granted
  /// (sending the user to grant it if not).
  Future<void> downloadAndInstall() async {
    if (!Platform.isAndroid || _busy) return;
    if (isDevBuild) {
      _set(UpdateStatus.error,
          error: 'This is a development build — auto-update is disabled.');
      return;
    }
    if (_latest == null) await check();
    final info = _latest;
    if (info == null || !info.isNewer) return;

    await refreshPermission();
    if (!_canInstall) {
      // Can't install yet — surface the prompt and stop at "available".
      _set(UpdateStatus.available);
      await requestInstallPermission();
      return;
    }

    _busy = true;
    _cancel = false;
    try {
      _set(UpdateStatus.downloading, progress: null);
      final file = await DownloadService.run(
        'Downloading Eva ${info.tag}',
        () => _downloadApk(info),
      );
      if (file == null) {
        if (_cancel) {
          _set(UpdateStatus.available);
        } else {
          _set(UpdateStatus.error, error: 'Download failed.');
        }
        return;
      }

      _set(UpdateStatus.verifying);
      final ok = await _verify(file, info.sha256Url);
      if (!ok) {
        try {
          await file.delete();
        } catch (_) {}
        _set(UpdateStatus.error,
            error: 'Downloaded file failed its integrity check.');
        return;
      }

      _set(UpdateStatus.readyToInstall);
      await _channel.invokeMethod('installApk', {'path': file.path});
      _set(UpdateStatus.installing);
    } on PlatformException catch (e) {
      _set(UpdateStatus.error, error: 'Install could not start: ${e.message}');
    } catch (e) {
      _set(UpdateStatus.error, error: 'Update failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// Cancels an in-flight download.
  void cancel() => _cancel = true;

  // ── Internals ───────────────────────────────────────────────────────────────

  Future<Directory> _updatesDir() async {
    final ext = await getExternalStorageDirectory();
    final base = ext?.path ?? (await getApplicationSupportDirectory()).path;
    final dir = Directory('$base/updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Streams the APK to disk with progress, replacing any previous download.
  /// Returns the file, or null if cancelled / failed.
  Future<File?> _downloadApk(ReleaseInfo info) async {
    final dir = await _updatesDir();
    // Drop any stale APKs so a half-finished one can't be installed by mistake.
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.apk')) await e.delete();
      }
    } catch (_) {}
    final safeTag = info.tag.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dest = File('${dir.path}/eva-$safeTag.apk');
    final tmp = File('${dest.path}.part');

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(info.apkUrl));
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return null;
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in resp.stream) {
          if (_cancel) {
            await sink.close();
            try {
              await tmp.delete();
            } catch (_) {}
            return null;
          }
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) {
            final p = received / total;
            _progress = p;
            DownloadService.update(
                'Eva ${info.tag} · ${(p * 100).round()}%');
            notifyListeners();
          }
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        await sink.close();
        return null;
      }
      if (await dest.exists()) await dest.delete();
      await tmp.rename(dest.path);
      return dest;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Verifies the APK's SHA-256 against the published checksum. Returns true if
  /// the checksum couldn't be fetched (best-effort) or it matches; false only on
  /// a definite mismatch.
  Future<bool> _verify(File apk, String? sha256Url) async {
    if (sha256Url == null) return true;
    String expected;
    try {
      final resp =
          await http.get(Uri.parse(sha256Url)).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return true; // can't verify — don't block
      // Format: "<hex>  filename" (or just the hex).
      expected = resp.body.trim().split(RegExp(r'\s+')).first.toLowerCase();
      if (expected.length != 64) return true;
    } catch (_) {
      return true; // offline mid-flow — don't block the install
    }
    try {
      final digest = await sha256.bind(apk.openRead()).first;
      return digest.toString().toLowerCase() == expected;
    } catch (_) {
      return true; // hashing error — don't block
    }
  }
}
