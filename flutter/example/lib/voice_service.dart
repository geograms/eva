import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Reports voice-model setup progress. [progress] is 0..1 while downloading,
/// null during the indeterminate unpack phase.
typedef VoiceProgress = void Function(String phase, double? progress);

/// On-device, fully offline streaming speech-to-text using a sherpa-onnx
/// streaming Zipformer2 (English). Loads in ~1-2s and transcribes in real time
/// as the user speaks — unlike Whisper, which must batch 30s chunks.
///
/// The model is downloaded once from the GitHub release (~57 MB) and cached in
/// the app's documents directory, then loaded via FFI. Mic audio is streamed
/// from the `record` plugin as 16 kHz mono PCM and fed to the recognizer.
class VoiceService {
  static const String _modelUrl =
      'https://github.com/geograms/eva/releases/latest/download/asr-en-streaming-zipformer.zip';

  // Folder name inside the zip and the files it must contain.
  static const String _dirName = 'asr-en';
  static const String _encoder =
      'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx';
  static const String _decoder = 'decoder-epoch-99-avg-1-chunk-16-left-128.onnx';
  static const String _joiner = 'joiner-epoch-99-avg-1-chunk-16-left-128.onnx';
  static const String _tokens = 'tokens.txt';

  static const int _sampleRate = 16000;

  final AudioRecorder _recorder = AudioRecorder();
  sherpa.OnlineRecognizer? _recognizer;
  dynamic _stream; // sherpa.OnlineStream
  StreamSubscription<Uint8List>? _audioSub;
  bool _listening = false;

  bool get isLoaded => _recognizer != null;
  bool get isListening => _listening;

  Future<Directory> _modelDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/asr/$_dirName');
  }

  /// Whether the speech model is already downloaded and unpacked.
  Future<bool> isModelInstalled() async {
    final dir = await _modelDir();
    for (final f in [_encoder, _decoder, _joiner, _tokens]) {
      if (!await File('${dir.path}/$f').exists()) return false;
    }
    return true;
  }

  /// Downloads + unpacks the speech model if it is not already present.
  Future<void> ensureModel(VoiceProgress onProgress) async {
    if (await isModelInstalled()) return;
    final docs = await getApplicationDocumentsDirectory();
    final asrRoot = Directory('${docs.path}/asr');
    await asrRoot.create(recursive: true);
    final zipPath = '${asrRoot.path}/asr-model.zip';

    onProgress('Downloading voice model…', null);
    await _download(_modelUrl, zipPath, onProgress);

    onProgress('Unpacking voice model…', null);
    await _extract(zipPath, asrRoot.path);
    try {
      await File(zipPath).delete();
    } catch (_) {/* best effort */}
  }

  Future<void> _download(
      String url, String outPath, VoiceProgress onProgress) async {
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) {
        throw Exception('Download failed (HTTP ${resp.statusCode})');
      }
      final total = resp.contentLength ?? 0;
      final sink = File(outPath).openWrite();
      int received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress('Downloading voice model…', received / total);
        }
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<void> _extract(String zipPath, String outDir) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive) {
      final path = '$outDir/${entry.name}';
      if (entry.isFile) {
        final f = File(path);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(path).create(recursive: true);
      }
    }
  }

  /// Loads the recognizer into memory. Call after [ensureModel]. Cheap to call
  /// repeatedly — it no-ops once loaded.
  Future<void> load() async {
    if (_recognizer != null) return;
    sherpa.initBindings();
    final dir = (await _modelDir()).path;
    final config = sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$dir/$_encoder',
          decoder: '$dir/$_decoder',
          joiner: '$dir/$_joiner',
        ),
        tokens: '$dir/$_tokens',
        modelType: 'zipformer2',
        numThreads: 2,
        debug: false,
      ),
      enableEndpoint: true,
    );
    _recognizer = sherpa.OnlineRecognizer(config);
  }

  /// Starts listening. [onText] is called with the running transcript (previous
  /// finalized utterances + the current partial) as it updates. Throws if the
  /// microphone permission is not granted.
  Future<void> start(void Function(String text) onText) async {
    if (_listening) return;
    if (!await _recorder.hasPermission()) {
      throw Exception('Microphone permission denied');
    }
    await load();
    _stream = _recognizer!.createStream();
    _listening = true;

    var finalized = '';
    final audio = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: 1,
    ));
    _audioSub = audio.listen((data) {
      if (!_listening) return;
      final samples = _pcm16ToFloat32(data);
      _stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
      while (_recognizer!.isReady(_stream)) {
        _recognizer!.decode(_stream);
      }
      final partial = _recognizer!.getResult(_stream).text;
      if (_recognizer!.isEndpoint(_stream)) {
        if (partial.trim().isNotEmpty) {
          finalized = finalized.isEmpty ? partial : '$finalized $partial';
        }
        _recognizer!.reset(_stream);
        onText(finalized);
      } else {
        final live = partial.isEmpty
            ? finalized
            : (finalized.isEmpty ? partial : '$finalized $partial');
        onText(live);
      }
    });
  }

  /// Stops listening and releases the audio stream. Returns once stopped.
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder.stop();
    } catch (_) {/* already stopped */}
    if (_stream != null) {
      _stream.free();
      _stream = null;
    }
  }

  void dispose() {
    _listening = false;
    _audioSub?.cancel();
    _recorder.dispose();
    _stream?.free();
    _recognizer?.free();
    _recognizer = null;
  }

  /// Converts little-endian 16-bit PCM bytes to normalized float samples.
  Float32List _pcm16ToFloat32(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final bd = ByteData.sublistView(bytes);
    final out = Float32List(n);
    for (int i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}
