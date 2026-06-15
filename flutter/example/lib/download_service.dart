import 'foreground_service.dart';

/// Keeps large downloads running while the app is backgrounded or the phone is
/// suspended, by holding the shared Android [ForegroundService] for the
/// duration of a download (see that class for the why).
///
/// This is a thin, download-flavoured facade over [ForegroundService] using the
/// hold key `download`. Reference-counted so nested/concurrent downloads share
/// one hold that's released when the last finishes.
class DownloadService {
  DownloadService._();

  static const String _key = 'download';
  static int _active = 0;

  /// Call once in `main()` before `runApp`.
  static void initCommunicationPort() => ForegroundService.initCommunicationPort();

  /// Runs [task] with the foreground service held for its whole duration.
  static Future<T> run<T>(String title, Future<T> Function() task) async {
    await begin(title);
    try {
      return await task();
    } finally {
      await end();
    }
  }

  /// Acquires the download hold (starts the service on the first download).
  static Future<void> begin(String title) async {
    _active++;
    if (_active == 1) {
      await ForegroundService.acquire(_key, title);
    } else {
      ForegroundService.setLabel(_key, title);
    }
  }

  /// Updates the notification text shown while downloading.
  static void update(String text) {
    if (_active > 0) ForegroundService.setLabel(_key, text);
  }

  /// Releases the download hold (stops the service when the last finishes).
  static Future<void> end() async {
    if (_active == 0) return;
    _active--;
    if (_active == 0) await ForegroundService.release(_key);
  }
}
