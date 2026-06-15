import 'dart:io' show Platform;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// A single Android foreground service shared by every long-running task that
/// must survive the app being backgrounded or the phone suspended — currently
/// downloads and background indexing.
///
/// Android freezes a backgrounded process and cuts its network under Doze, which
/// stalls in-flight work. A foreground service (with a wake + wifi lock) holds
/// the process at foreground priority so the work — which keeps running on the
/// main isolate — isn't frozen, and it shows a persistent notification.
///
/// flutter_foreground_task allows only one service instance, so this is a
/// process-wide registry of named **holds**: the service starts on the first
/// hold and stops when the last is released. The notification text is the
/// combined labels of the active holds. A no-op on non-Android platforms (the
/// work still runs, just without the keep-alive).
class ForegroundService {
  ForegroundService._();

  // Arbitrary stable id for our service notification ('evfs').
  static const int _serviceId = 0x65766673;

  static bool _inited = false;
  static bool _running = false;
  // Active holds, in insertion order: key -> notification label.
  static final Map<String, String> _holds = <String, String>{};
  // Serializes start/stop so concurrent acquire/release can't double-start.
  static Future<void> _lock = Future<void>.value();

  static bool get _supported => Platform.isAndroid;

  /// Call once in `main()` before `runApp` (required by flutter_foreground_task
  /// so the background isolate can talk to the plugin).
  static void initCommunicationPort() {
    if (_supported) FlutterForegroundTask.initCommunicationPort();
  }

  static Future<T> _sync<T>(Future<T> Function() op) {
    final next = _lock.then((_) => op());
    // Keep the chain alive regardless of individual op failures.
    _lock = next.then((_) {}, onError: (_) {});
    return next;
  }

  static String _text() =>
      _holds.isEmpty ? 'Working…' : _holds.values.join(' · ');

  static Future<void> _ensureInit() async {
    if (_inited) return;
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'eva_background',
        channelName: 'Background work',
        channelDescription:
            'Keeps downloads and indexing running in the background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // The work runs on the main isolate; the service just keeps the process
        // alive, so the background handler needs no periodic events.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _inited = true;
  }

  /// Adds a hold under [key] (replacing any existing one) and ensures the
  /// service is running. The first hold starts it; later holds just update the
  /// notification.
  static Future<void> acquire(String key, String label) {
    if (!_supported) return Future<void>.value();
    return _sync(() async {
      _holds[key] = label;
      try {
        if (!_running) {
          await _ensureInit();
          if (await FlutterForegroundTask.isRunningService) {
            _running = true;
            FlutterForegroundTask.updateService(notificationText: _text());
          } else {
            await FlutterForegroundTask.startService(
              serviceId: _serviceId,
              serviceTypes: const [ForegroundServiceTypes.dataSync],
              notificationTitle: 'Eva',
              notificationText: _text(),
              notificationIcon: null,
              notificationButtons: const [],
              notificationInitialRoute: '/',
              callback: foregroundServiceCallback,
            );
            _running = true;
          }
        } else {
          FlutterForegroundTask.updateService(notificationText: _text());
        }
      } catch (_) {
        // Couldn't start (e.g. notifications denied): drop the hold so the ref
        // count stays honest. Work still proceeds, just without keep-alive.
        _holds.remove(key);
      }
    });
  }

  /// Updates the notification label of an existing hold (e.g. live progress).
  static void setLabel(String key, String label) {
    if (!_supported || !_holds.containsKey(key)) return;
    _holds[key] = label;
    if (_running) FlutterForegroundTask.updateService(notificationText: _text());
  }

  /// Releases the hold under [key]; stops the service when the last is gone.
  static Future<void> release(String key) {
    if (!_supported) return Future<void>.value();
    return _sync(() async {
      if (_holds.remove(key) == null) return;
      if (_holds.isEmpty) {
        if (_running) {
          try {
            await FlutterForegroundTask.stopService();
          } catch (_) {}
          _running = false;
        }
      } else if (_running) {
        FlutterForegroundTask.updateService(notificationText: _text());
      }
    });
  }
}

/// Background-isolate entry point. The actual work runs on the main isolate;
/// this handler exists only because the plugin requires one. It does no work —
/// the service's sole job is to keep the process alive so the main-isolate work
/// isn't frozen while backgrounded.
@pragma('vm:entry-point')
void foregroundServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
