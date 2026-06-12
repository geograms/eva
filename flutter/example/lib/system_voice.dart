import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Speech-to-text using the phone's built-in recognizer (Android's speech
/// service). Supports many languages — including the system language and
/// Portuguese — with no model download. It uses whatever offline language
/// packs the device has installed.
///
/// This is offered as an alternative to the bundled English [VoiceService];
/// the user picks which one the mic uses in Settings.
class SystemVoiceService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _available = false;
  bool _listening = false;

  bool get isListening => _listening;

  /// Initializes the platform recognizer. Returns false if the device has no
  /// speech recognition service available.
  Future<bool> init({void Function()? onStopped}) async {
    if (_available) return true;
    _available = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          _listening = false;
          onStopped?.call();
        }
      },
      onError: (_) {
        _listening = false;
        onStopped?.call();
      },
    );
    return _available;
  }

  /// Available recognition locales (id + display name), e.g. `pt_BR`.
  Future<List<stt.LocaleName>> locales() async {
    if (!_available) await init();
    return _speech.locales();
  }

  /// The device's default recognition locale, if known.
  Future<stt.LocaleName?> systemLocale() async {
    if (!_available) await init();
    return _speech.systemLocale();
  }

  /// Starts listening. [onText] receives the running transcript; [onStopped]
  /// fires when the recognizer ends (silence timeout, error, or stop()).
  /// [localeId] empty → let the recognizer use the system default.
  Future<void> start(
    String? localeId,
    void Function(String text) onText, {
    void Function()? onStopped,
  }) async {
    final ok = await init(onStopped: onStopped);
    if (!ok) {
      throw Exception('Speech recognition is not available on this device');
    }
    _listening = true;
    await _speech.listen(
      onResult: (SpeechRecognitionResult r) => onText(r.recognizedWords),
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        cancelOnError: true,
        localeId: (localeId == null || localeId.isEmpty) ? null : localeId,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 8),
      ),
    );
  }

  Future<void> stop() async {
    _listening = false;
    try {
      await _speech.stop();
    } catch (_) {/* already stopped */}
  }

  void dispose() {
    try {
      _speech.cancel();
    } catch (_) {}
  }
}
