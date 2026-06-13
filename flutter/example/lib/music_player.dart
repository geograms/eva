import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'music_service.dart';
import 'music_store.dart';

/// In-app music player: wraps a [just_audio] player with a track queue and
/// records each play so the catalog can rank the user's favourites. Exposed as
/// a [ChangeNotifier] so the chat screen can show a now-playing bar.
class MusicPlayer extends ChangeNotifier {
  MusicPlayer(this._music) {
    _player.playerStateStream.listen((s) {
      _playing = s.playing;
      notifyListeners();
    });
    // When the player advances to a new track, surface it and count the play.
    _player.currentIndexStream.listen((i) {
      if (i == null || i < 0 || i >= _queue.length) return;
      _index = i;
      _recordPlay(_queue[i]);
      notifyListeners();
    });
  }

  final MusicService _music;
  final AudioPlayer _player = AudioPlayer();

  List<TrackInfo> _queue = const [];
  int _index = -1;
  bool _playing = false;
  final Set<int> _counted = {}; // track ids already counted this session-queue

  bool get hasTrack => _index >= 0 && _index < _queue.length;
  bool get isPlaying => _playing;
  int get queueLength => _queue.length;
  TrackInfo? get current => hasTrack ? _queue[_index] : null;

  /// Position/duration streams for an optional progress UI.
  Stream<Duration> get positionStream => _player.positionStream;
  Duration? get duration => _player.duration;

  /// Replaces the queue with [tracks] and starts playing from [startAt].
  Future<void> playQueue(List<TrackInfo> tracks, {int startAt = 0}) async {
    if (tracks.isEmpty) return;
    _queue = tracks;
    _counted.clear();
    _index = startAt.clamp(0, tracks.length - 1);
    final sources = [
      for (final t in tracks) AudioSource.uri(Uri.file(t.path)),
    ];
    try {
      await _player.setAudioSources(sources, initialIndex: _index);
      await _player.play();
    } catch (_) {
      // A missing/unsupported file shouldn't crash playback control.
    }
    notifyListeners();
  }

  Future<void> toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();

  Future<void> next() async {
    if (_player.hasNext) await _player.seekToNext();
  }

  Future<void> previous() async {
    // Restart the current track if we're past its start, else go back one.
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
    } else if (_player.hasPrevious) {
      await _player.seekToPrevious();
    } else {
      await _player.seek(Duration.zero);
    }
  }

  Future<void> stop() async {
    await _player.stop();
    _queue = const [];
    _index = -1;
    _playing = false;
    notifyListeners();
  }

  void _recordPlay(TrackInfo t) {
    if (!_counted.add(t.id)) return; // count each track once per queue
    unawaited(_music
        .recordPlay(t.id, DateTime.now().millisecondsSinceEpoch)
        .catchError((_) {}));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
