import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'cactus.dart' as cactus;

/// Drives the native Cactus model from a dedicated worker isolate.
///
/// All FFI calls (`cactus_init`, `cactus_complete`) block the calling thread,
/// so they must not run on the UI isolate — otherwise the app would freeze
/// (and ANR) while a model loads or generates. This class owns a long-lived
/// worker isolate that holds the model pointer and streams tokens back.
class InferenceEngine {
  final ReceivePort _fromWorker = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  late SendPort _toWorker;

  Completer<void>? _initCompleter;
  Completer<void>? _resetCompleter;
  Completer<void>? _embedderCompleter;
  Completer<List<Float32List>>? _embedCompleter;
  // Serializes embed requests: the worker handles one command at a time and we
  // keep a single in-flight completer, so concurrent callers (background indexer
  // + chat query) must not overlap. Each call chains after the previous.
  Future<void> _embedGate = Future<void>.value();
  StreamController<String>? _tokenController;
  Completer<Map<String, dynamic>>? _doneCompleter;

  bool get isBusy => _tokenController != null;

  Future<void> start() async {
    _fromWorker.listen(_onMessage);
    await Isolate.spawn(_workerMain, _fromWorker.sendPort);
    await _ready.future;
  }

  void _onMessage(dynamic msg) {
    if (msg is SendPort) {
      _toWorker = msg;
      _ready.complete();
      return;
    }
    final m = msg as Map;
    switch (m['type'] as String) {
      case 'init_done':
        _initCompleter?.complete();
        _initCompleter = null;
        break;
      case 'init_error':
        _initCompleter?.completeError(Exception(m['message']));
        _initCompleter = null;
        break;
      case 'reset_done':
        _resetCompleter?.complete();
        _resetCompleter = null;
        break;
      case 'embedder_done':
        _embedderCompleter?.complete();
        _embedderCompleter = null;
        break;
      case 'embedder_error':
        _embedderCompleter?.completeError(Exception(m['message']));
        _embedderCompleter = null;
        break;
      case 'embed_result':
        _embedCompleter?.complete(
            (m['vectors'] as List).cast<Float32List>());
        _embedCompleter = null;
        break;
      case 'embed_error':
        _embedCompleter?.completeError(Exception(m['message']));
        _embedCompleter = null;
        break;
      case 'token':
        _tokenController?.add(m['text'] as String);
        break;
      case 'complete_done':
        _doneCompleter?.complete(Map<String, dynamic>.from(m['result'] as Map));
        _tokenController?.close();
        _tokenController = null;
        _doneCompleter = null;
        break;
      case 'complete_error':
        final err = Exception(m['message']);
        _tokenController?.addError(err);
        _tokenController?.close();
        _tokenController = null;
        _doneCompleter?.completeError(err);
        _doneCompleter = null;
        break;
    }
  }

  /// Loads the model from a directory of converted weights with the given
  /// KV-cache context window (in tokens).
  Future<void> initModel(String modelDir, {int contextSize = 4096}) {
    _initCompleter = Completer<void>();
    _toWorker.send({
      'cmd': 'init',
      'modelDir': modelDir,
      'contextSize': contextSize,
    });
    return _initCompleter!.future;
  }

  /// Clears the conversation KV cache (starts a fresh conversation).
  Future<void> reset() {
    _resetCompleter = Completer<void>();
    _toWorker.send({'cmd': 'reset'});
    return _resetCompleter!.future;
  }

  /// Loads the embedding model from [embedderDir] alongside the chat model, for
  /// computing document/query embeddings (RAG). No corpus is built here — the
  /// vector index is managed app-side via usearch.
  Future<void> loadEmbedder(String embedderDir) {
    _embedderCompleter = Completer<void>();
    _toWorker.send({'cmd': 'load_embedder', 'embedderDir': embedderDir});
    return _embedderCompleter!.future;
  }

  /// Frees the embedding model (e.g. when no documents remain).
  Future<void> freeEmbedder() {
    _embedderCompleter = Completer<void>();
    _toWorker.send({'cmd': 'free_embedder'});
    return _embedderCompleter!.future;
  }

  /// Embeds each text in [texts] with the loaded embedder, returning a unit-norm
  /// vector per text (in order).
  Future<List<Float32List>> embedBatch(List<String> texts) {
    final result = _embedGate.then((_) {
      _embedCompleter = Completer<List<Float32List>>();
      _toWorker.send({'cmd': 'embed_batch', 'texts': texts});
      return _embedCompleter!.future;
    });
    // Keep the gate open for the next caller regardless of this call's outcome.
    _embedGate = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Runs a chat completion. [messagesJson] is a JSON array of
  /// `{"role":..., "content":...}`. The returned `tokens` stream emits each
  /// generated token as it arrives; `stats` completes with the parsed result
  /// JSON (`response`, `decode_tps`, …) when generation finishes.
  ({Stream<String> tokens, Future<Map<String, dynamic>> stats}) complete(
    String messagesJson, {
    String? optionsJson,
  }) {
    _tokenController = StreamController<String>();
    _doneCompleter = Completer<Map<String, dynamic>>();
    _toWorker.send({
      'cmd': 'complete',
      'messages': messagesJson,
      'options': optionsJson,
    });
    return (tokens: _tokenController!.stream, stats: _doneCompleter!.future);
  }
}

void _workerMain(SendPort toMain) {
  final port = ReceivePort();
  toMain.send(port.sendPort);

  cactus.CactusModelT? model;
  cactus.CactusModelT? embedder; // dedicated embedding model for document RAG

  port.listen((msg) {
    final m = msg as Map;
    final cmd = m['cmd'] as String;
    try {
      switch (cmd) {
        case 'init':
          // Destroy any currently-loaded model so this also handles switching.
          final existing = model;
          if (existing != null) {
            cactus.cactusDestroy(existing);
            model = null;
          }
          model = cactus.cactusInitWithContext(
            m['modelDir'] as String,
            null,
            false,
            m['contextSize'] as int,
          );
          toMain.send({'type': 'init_done'});
          break;
        case 'reset':
          final handle = model;
          if (handle != null) cactus.cactusReset(handle);
          toMain.send({'type': 'reset_done'});
          break;
        case 'load_embedder':
          // Load the embedding model (no corpus — the vector index is app-side).
          final existing = embedder;
          if (existing != null) {
            cactus.cactusDestroy(existing);
            embedder = null;
          }
          embedder = cactus.cactusInit(m['embedderDir'] as String, null, false);
          toMain.send({'type': 'embedder_done'});
          break;
        case 'free_embedder':
          final handle = embedder;
          if (handle != null) {
            cactus.cactusDestroy(handle);
            embedder = null;
          }
          toMain.send({'type': 'embedder_done'});
          break;
        case 'embed_batch':
          final handle = embedder;
          if (handle == null) {
            toMain.send({'type': 'embed_error', 'message': 'Embedder not loaded'});
            break;
          }
          final texts = (m['texts'] as List).cast<String>();
          final vectors = <Float32List>[
            for (final t in texts) cactus.cactusEmbed(handle, t, true)
          ];
          toMain.send({'type': 'embed_result', 'vectors': vectors});
          break;
        case 'complete':
          final handle = model;
          if (handle == null) {
            toMain.send({'type': 'complete_error', 'message': 'Model not initialized'});
            break;
          }
          final result = cactus.cactusComplete(
            handle,
            m['messages'] as String,
            m['options'] as String?,
            null,
            (token, _) => toMain.send({'type': 'token', 'text': token}),
          );
          Map<String, dynamic> parsed;
          try {
            parsed = jsonDecode(result) as Map<String, dynamic>;
          } catch (_) {
            parsed = {'response': result};
          }
          toMain.send({'type': 'complete_done', 'result': parsed});
          break;
      }
    } catch (e) {
      final errorType = switch (cmd) {
        'init' => 'init_error',
        'load_embedder' || 'free_embedder' => 'embedder_error',
        'embed_batch' => 'embed_error',
        _ => 'complete_error',
      };
      toMain.send({'type': errorType, 'message': e.toString()});
    }
  });
}
