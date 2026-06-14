import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Schedules timed reminders as real OS notifications (they fire even when Eva
/// is backgrounded or the screen is off). Used by the chat "remind me…" intent.
class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const String _channelId = 'eva_reminders';
  static const String _channelName = 'Reminders';

  /// Initialises the timezone database (so absolute times land in the device's
  /// local zone) and the notifications plugin. Safe to call more than once.
  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // Falls back to UTC; relative reminders ("in 15 minutes") still fire at
      // the right instant since they're computed from now.
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
    );
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Timed reminders you ask Eva to set',
        importance: Importance.max,
      ),
    );
    _ready = true;
  }

  /// Requests the runtime permissions reminders need (notifications on Android
  /// 13+, exact alarms on Android 12+). Returns true if notifications are
  /// permitted. Best-effort: missing exact-alarm permission downgrades to an
  /// inexact alarm rather than failing.
  Future<bool> requestPermissions() async {
    await init();
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final granted = await androidImpl?.requestNotificationsPermission();
    await androidImpl?.requestExactAlarmsPermission();
    return granted ?? true;
  }

  /// Schedules a notification with [title]/[body] to fire at [when]. Returns the
  /// notification id (so it can be cancelled). Uses an exact alarm when allowed,
  /// otherwise an inexact one.
  Future<int> schedule(DateTime when, String title, String body,
      {required int id}) async {
    await init();
    final scheduled = tz.TZDateTime.from(when, tz.local);
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Timed reminders you ask Eva to set',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
      ),
    );
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
    return id;
  }

  /// Whether the OS currently allows Eva to post notifications.
  Future<bool> notificationsEnabled() async {
    await init();
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await androidImpl?.areNotificationsEnabled() ?? true;
  }

  Future<void> cancel(int id) async {
    await init();
    await _plugin.cancel(id);
  }

  Future<List<PendingNotificationRequest>> pending() async {
    await init();
    return _plugin.pendingNotificationRequests();
  }
}
