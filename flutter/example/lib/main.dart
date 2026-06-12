import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:file_picker/file_picker.dart';

import 'package:flutter_tts/flutter_tts.dart';

import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_prefs.dart';
import 'assistant_channel.dart';
import 'background_indexer.dart';
import 'chat_store.dart';
import 'document_service.dart';
import 'inference_isolate.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'rag_index.dart';
import 'settings_screen.dart';
import 'system_voice.dart';
import 'update_check.dart';
import 'voice_service.dart';

const Color _seedColor = Color(0xFF2E7D32);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initThemeMode();
  runApp(const EvaApp());
}

class EvaApp extends StatelessWidget {
  const EvaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: 'Eva',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: _seedColor),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: _seedColor,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: mode,
        home: const ChatScreen(),
      ),
    );
  }
}

enum AppPhase { preparing, downloading, loadingModel, ready, error }

class ChatMessage {
  ChatMessage(this.role, this.text, {this.imagePath, this.sources});
  final String role; // 'user' or 'assistant'
  String text;
  // Absolute path of an image the user attached to this message (vision chat).
  final String? imagePath;
  // Document sources cited for this answer (RAG), shown under the bubble.
  List<String>? sources;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ModelManager _models = ModelManager();
  final InferenceEngine _engine = InferenceEngine();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<ChatMessage> _messages = [];
  // Persistent chat history: current conversation + drawer list.
  ChatStore? _chats;
  int? _convId;
  List<ConversationInfo> _convs = const [];
  final ImagePicker _picker = ImagePicker();
  final VoiceService _voice = VoiceService();
  final SystemVoiceService _systemVoice = SystemVoiceService();
  final DocumentService _docs = DocumentService();
  bool _listening = false;
  VoiceEngine _voiceEngine = VoiceEngine.fast;
  String _voiceLocale = '';
  List<DocumentInfo> _documents = const [];
  String _corpusLocation = '';
  RagIndex? _rag;
  IndexingController? _indexer;
  bool _embedderReady = false;
  bool _docBusy = false;
  String _systemPrompt = kDefaultSystemPrompt;
  int _maxTokens = kDefaultMaxTokens;
  List<ModelSpec> _catalog = kBuiltinCatalog;
  String _activeModelId = kDefaultModelId;
  AppPhase _phase = AppPhase.preparing;
  String _statusText = 'Starting…';
  double? _progress;
  String? _lastStats;
  bool _generating = false;
  // Image queued by the user for the next message (vision models only).
  String? _pendingImagePath;
  // Digital-assistant mode (invoked via the power button): speaks replies and
  // auto-listens. _assistPending = a turn is queued until the model is ready.
  final FlutterTts _tts = FlutterTts();
  bool _assistMode = false;
  bool _assistPending = false;
  // Language of the current turn (base code like 'en'), detected once from the
  // user's input and used for both the model directive and the TTS voice, so
  // input, reply and speech stay in the same language.
  String? _turnLang;
  // Tag of a newer published release (shows the update banner), and a
  // dismissible notice for failures that would otherwise be silent.
  String? _updateTag;
  String? _notice;
  Object? _seenIndexError;

  /// Whether the active model can see images (exposes the attach button).
  bool get _visionActive => modelById(_catalog, _activeModelId).isVision;

  @override
  void initState() {
    super.initState();
    _setupAssistant();
    _bootstrap();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _voice.dispose();
    _systemVoice.dispose();
    _tts.stop();
    _indexer?.removeListener(_onIndexerProgress);
    _indexer?.dispose();
    _rag?.close();
    _chats?.close();
    super.dispose();
  }

  // ── Chat history (persistence + conversation list) ─────────────────────────

  /// Opens the chat store and restores the most recent conversation, so the
  /// chat survives app restarts.
  Future<void> _openChatStore() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      _chats = ChatStore.open('${docs.path}/chats.sqlite');
      _convs = _chats!.listConversations();
      final latest = _chats!.latestConversationId();
      if (latest != null) _restoreConversation(latest);
    } catch (_) {/* history unavailable — chat still works, unpersisted */}
  }

  void _restoreConversation(int id) {
    final stored = _chats?.messages(id);
    if (stored == null) return;
    _convId = id;
    _messages
      ..clear()
      ..addAll(stored.map((m) => ChatMessage(
            m.role,
            m.text,
            // Attached images live in a cache dir and may have been purged.
            imagePath: (m.imagePath != null && File(m.imagePath!).existsSync())
                ? m.imagePath
                : null,
            sources: m.sources,
          )));
    if (mounted) setState(() {});
  }

  /// Switches the UI (and the model's KV cache) to conversation [id].
  Future<void> _openConversation(int id) async {
    if (_generating || id == _convId) return;
    await _engine.reset();
    _restoreConversation(id);
    _scrollToBottom();
  }

  /// Persists [m] into the current conversation, creating the conversation on
  /// the first message (titled from it).
  void _persistMessage(ChatMessage m) {
    final chats = _chats;
    if (chats == null || m.text.isEmpty && m.imagePath == null) return;
    try {
      if (_convId == null) {
        final title = m.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        _convId = chats.createConversation(
            title.length > 40 ? '${title.substring(0, 40)}…' : title);
      }
      chats.addMessage(
          _convId!,
          StoredMessage(
              role: m.role,
              text: m.text,
              imagePath: m.imagePath,
              sources: m.sources));
      _convs = chats.listConversations();
    } catch (_) {/* persistence is best-effort */}
  }

  Future<void> _renameConversation(ConversationInfo c) async {
    final ctl = TextEditingController(text: c.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('Rename')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      _chats?.renameConversation(c.id, name);
      setState(() => _convs = _chats?.listConversations() ?? _convs);
    }
  }

  Future<void> _deleteConversation(ConversationInfo c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${c.title}"?'),
        content: const Text('This removes the chat permanently.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    _chats?.deleteConversation(c.id);
    if (c.id == _convId) {
      _convId = null;
      _messages.clear();
      await _engine.reset();
    }
    setState(() => _convs = _chats?.listConversations() ?? _convs);
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: const Text('New chat'),
              onTap: () {
                Navigator.pop(context);
                _newChat();
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: _convs.isEmpty
                  ? const Center(child: Text('No chats yet.'))
                  : ListView.builder(
                      itemCount: _convs.length,
                      itemBuilder: (context, i) {
                        final c = _convs[i];
                        return ListTile(
                          selected: c.id == _convId,
                          leading: const Icon(Icons.chat_bubble_outline),
                          title: Text(c.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            Navigator.pop(context);
                            _openConversation(c.id);
                          },
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) => v == 'rename'
                                ? _renameConversation(c)
                                : _deleteConversation(c),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'rename', child: Text('Rename')),
                              PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Digital assistant (power-button invocation) ────────────────────────────

  /// Wires up assistant mode: handles invocations that arrive while running and
  /// detects whether this launch itself was an assistant invocation.
  Future<void> _setupAssistant() async {
    AssistantChannel.setAssistHandler(() {
      _assistMode = true;
      _assistPending = true;
      _tryStartAssistTurn();
    });
    if (await AssistantChannel.consumeAssistLaunch()) {
      _assistMode = true;
      _assistPending = true;
      _tryStartAssistTurn(); // no-op until the model is ready
    }
  }

  /// Starts a hands-free assist turn once the model is ready and idle.
  Future<void> _tryStartAssistTurn() async {
    if (!_assistPending || _phase != AppPhase.ready) return;
    if (_generating || _listening) return;
    _assistPending = false;
    await _startAssistListening();
  }

  /// Listens via the phone recognizer (auto-stops on silence), then sends the
  /// transcript. The reply is spoken because [_assistMode] is set.
  Future<void> _startAssistListening() async {
    await _tts.stop();
    await _voice.stop();
    await _systemVoice.stop();
    _input.clear();
    void onText(String t) {
      _input.text = t;
      _input.selection = TextSelection.collapsed(offset: t.length);
    }

    try {
      await _systemVoice.start(_voiceLocale, onText, onStopped: () {
        if (!mounted) return;
        final q = _normalizeCase(_input.text.trim());
        setState(() {
          _listening = false;
          _input.text = q;
        });
        if (q.isNotEmpty && !_generating) _send();
      });
      if (mounted) setState(() => _listening = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Assistant voice unavailable: $e')),
        );
      }
    }
  }

  /// Speaks [text] aloud (assistant replies), matching the TTS voice to the
  /// language of the text itself (so e.g. an English reply isn't read with a
  /// Portuguese voice). Markdown is lightly stripped.
  Future<void> _speak(String text) async {
    final clean = text
        .replaceAll(RegExp(r'[*_`#>]+'), '')
        .replaceAll(RegExp(r'\[(.*?)\]\(.*?\)'), r'$1')
        .trim();
    if (clean.isEmpty) return;
    try {
      // Voice priority: the language the user spoke this turn, then the
      // language detected in the reply text, then the configured voice locale.
      final tag = _ttsLocaleFor(_turnLang ?? _detectLangBase(clean)) ??
          (_voiceLocale.isNotEmpty ? _voiceLocale.replaceAll('_', '-') : null);
      if (tag != null && (await _tts.isLanguageAvailable(tag)) == true) {
        await _tts.setLanguage(tag);
      }
      await _tts.speak(clean);
    } catch (_) {/* TTS unavailable — silently skip */}
  }

  /// Instruction (used in assistant mode) keeping the reply in the user's
  /// language. When the input language was detected, name it explicitly — far
  /// more reliable with small models than a generic "same language" rule.
  String get _assistLangDirective {
    const names = {
      'en': 'English',
      'pt': 'Portuguese',
      'fr': 'French',
      'es': 'Spanish',
      'de': 'German',
      'it': 'Italian',
    };
    final name = names[_turnLang];
    return name != null
        ? 'Reply only in $name. Do not use any other language.'
        : 'Always reply in the same language the user used in their most '
            'recent message. Do not switch to a different language.';
  }

  /// Lower-cases an ALL-CAPS transcript (some recognizers return uppercase) and
  /// capitalizes sentence starts. Leaves already-mixed-case text untouched so
  /// recognizers that capitalize names/`I` correctly are not degraded.
  String _normalizeCase(String s) {
    final letters = s.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (letters.length < 2 || s != s.toUpperCase()) return s;
    final out = StringBuffer();
    var capNext = true;
    for (final ch in s.toLowerCase().runes) {
      final c = String.fromCharCode(ch);
      final isLetter = RegExp(r'[a-z]').hasMatch(c);
      if (capNext && isLetter) {
        out.write(c.toUpperCase());
        capNext = false;
      } else {
        out.write(c);
        if (c == '.' || c == '!' || c == '?' || c == '\n') capNext = true;
      }
    }
    // Standalone English "i" → "I".
    return out
        .toString()
        .replaceAllMapped(RegExp(r'\bi\b'), (_) => 'I');
  }

  /// Best-effort language of [text] (base code like en/pt/fr) by counting common
  /// words, used only to pick a TTS voice. Returns null when unsure.
  String? _detectLangBase(String text) {
    const stop = {
      'en': ['the', 'and', 'is', 'are', 'you', 'your', 'what', 'how', 'with',
          'this', 'that', 'have', 'for', 'will', 'can', 'not', 'it'],
      'pt': ['que', 'não', 'você', 'está', 'com', 'uma', 'para', 'obrigado',
          'isso', 'tem', 'são', 'mais', 'também', 'sim'],
      'fr': ['le', 'la', 'les', 'est', 'vous', 'je', 'bonjour', 'merci', 'pas',
          'avec', 'pour', 'une', 'des', 'oui'],
      'es': ['que', 'el', 'los', 'está', 'usted', 'gracias', 'con', 'para',
          'una', 'hola', 'qué', 'pero', 'sí', 'más'],
      'de': ['der', 'die', 'das', 'und', 'ist', 'ich', 'nicht', 'mit', 'ein',
          'wie', 'danke', 'ja', 'auch'],
      'it': ['che', 'non', 'sono', 'con', 'una', 'per', 'grazie', 'come',
          'questo', 'il', 'sì', 'anche', 'più'],
    };
    final words =
        text.toLowerCase().split(RegExp(r'[^a-zà-ÿ]+')).where((w) => w.isNotEmpty);
    final counts = <String, int>{};
    for (final w in words) {
      stop.forEach((lang, list) {
        if (list.contains(w)) counts[lang] = (counts[lang] ?? 0) + 1;
      });
    }
    if (counts.isEmpty) return null;
    final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return best.value >= 2 ? best.key : null;
  }

  String? _ttsLocaleFor(String? base) {
    switch (base) {
      case 'en':
        return 'en-US';
      case 'pt':
        return 'pt-PT';
      case 'fr':
        return 'fr-FR';
      case 'es':
        return 'es-ES';
      case 'de':
        return 'de-DE';
      case 'it':
        return 'it-IT';
      default:
        return null;
    }
  }

  Future<void> _bootstrap() async {
    // Non-blocking: shows a banner if a newer release was published.
    unawaited(checkForNewerRelease().then((tag) {
      if (tag != null && mounted) setState(() => _updateTag = tag);
    }));
    await _engine.start();
    await _openChatStore();
    _systemPrompt = await loadSystemPrompt();
    _maxTokens = await loadMaxTokens();
    _voiceEngine = await loadVoiceEngine();
    _voiceLocale = await loadVoiceLocale();
    _corpusLocation = await loadCorpusLocation();
    _documents = await _docs.list();
    _catalog = await loadCatalog();
    final prefs = await SharedPreferences.getInstance();
    _activeModelId = prefs.getString('selected_model') ?? kDefaultModelId;
    // A previously-selected model may be gone; if so, fall back to the default
    // (downloaded automatically on first use by _prepareAndLoad below).
    final spec = modelById(_catalog, _activeModelId);
    if (!spec.isBundled && !await _models.isInstalled(spec)) {
      _activeModelId = kDefaultModelId;
    }
    await _prepareAndLoad();
  }

  Future<void> _prepareAndLoad() async {
    final spec = modelById(_catalog, _activeModelId);
    setState(() {
      _phase = AppPhase.downloading;
      _statusText = 'Preparing model…';
      _progress = null;
    });
    try {
      final path = await _models.ensureInstalled(spec, (phase, progress) {
        if (!mounted) return;
        setState(() {
          _statusText = phase;
          _progress = progress;
        });
      });
      await _loadModel(path);
    } catch (e) {
      setState(() {
        _phase = AppPhase.error;
        _statusText = 'Failed to prepare model: $e';
      });
    }
  }

  Future<void> _openSettings() async {
    final newId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          activeId: _activeModelId,
          manager: _models,
        ),
      ),
    );
    // Persona, voice settings, documents and sideloaded models may have changed.
    _systemPrompt = await loadSystemPrompt();
    _maxTokens = await loadMaxTokens();
    _voiceEngine = await loadVoiceEngine();
    _voiceLocale = await loadVoiceLocale();
    final docsBefore = _documents.map((d) => d.id).toSet();
    final locBefore = _corpusLocation;
    _corpusLocation = await loadCorpusLocation();
    _documents = await _docs.list();
    final docsNow = _documents.map((d) => d.id).toSet();
    // A changed corpus location closes the current index (it lives in the pack).
    if (_corpusLocation != locBefore) {
      await _indexer?.stop();
      _rag?.close();
      _rag = null;
      _embedderReady = false;
    }
    // Documents removed in Settings must be dropped from the index too.
    final removed = docsBefore.difference(docsNow);
    if (removed.isNotEmpty) {
      try {
        _rag ??= await RagIndex.open(await _docs.corpusPath());
        for (final id in removed) {
          _rag!.removeDocument(id);
        }
      } catch (_) {/* index will reconcile on next open */}
    }
    _catalog = await loadCatalog();
    if (newId == null || newId == _activeModelId) {
      if (mounted) setState(() {});
      return;
    }
    _activeModelId = newId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_model', newId);
    setState(() {
      _messages.clear();
      _lastStats = null;
    });
    await _prepareAndLoad();
  }

  Future<void> _loadModel(String modelDir) async {
    setState(() {
      _phase = AppPhase.loadingModel;
      _statusText = 'Loading model…';
      _progress = null;
    });
    try {
      await _engine.initModel(modelDir);
      setState(() => _phase = AppPhase.ready);
      _tryStartAssistTurn(); // run any assist turn queued during startup
    } catch (e) {
      setState(() {
        _phase = AppPhase.error;
        _statusText = 'Failed to load model: $e';
      });
    }
  }

  Future<void> _send() async {
    var text = _input.text.trim();
    final imagePath = _pendingImagePath;
    // Allow sending an image on its own with a sensible default question.
    if (text.isEmpty && imagePath == null) return;
    if (_generating) return;
    await _tts.stop(); // don't talk over the next turn
    // Pin this turn's language from the user's own words (keeps directive and
    // TTS voice consistent; falls back to the previous turn's when unsure).
    _turnLang = _detectLangBase(text) ?? _turnLang;
    // Sending finalizes any in-progress dictation.
    if (_voice.isListening || _systemVoice.isListening) {
      await _voice.stop();
      await _systemVoice.stop();
      if (mounted) setState(() => _listening = false);
    }
    if (text.isEmpty && imagePath != null) text = 'What is in this image?';
    _input.clear();

    final assistant = ChatMessage('assistant', '');
    final user = ChatMessage('user', text, imagePath: imagePath);
    setState(() {
      _messages.add(user);
      _messages.add(assistant);
      _generating = true;
      _lastStats = null;
      _pendingImagePath = null;
    });
    _persistMessage(user);
    _scrollToBottom();

    // When documents are loaded, retrieve relevant passages and ground the
    // answer on them (RAG). The retrieved excerpts augment the system prompt.
    var systemContent = _systemPrompt;
    List<String>? sources;
    if (_documents.isNotEmpty) {
      try {
        await _ensureRag();
        // Yield the embedder to this turn; query whatever is already indexed
        // (background indexing continues afterward). Resumed in the finally.
        await _indexer?.stop();
        final qvec = (await _engine.embedBatch([text])).first;
        final hits = await _rag!
            .query(queryVec: qvec, queryText: text, topK: 4);
        if (hits.isNotEmpty) {
          final buf = StringBuffer(_systemPrompt);
          buf.writeln(
              "\n\nAnswer the user's question using ONLY the document excerpts below. "
              'Cite the source document (and page if shown). If the answer is not '
              'in them, say you could not find it in the documents.\n');
          final cited = <String>{};
          for (final h in hits) {
            buf.writeln('\n--- Source: ${h.docName}'
                '${h.page != null ? ' (page ${h.page})' : ''} ---');
            buf.writeln(h.text.trim());
            cited.add(h.page != null ? '${h.docName} (p.${h.page})' : h.docName);
          }
          systemContent = buf.toString();
          sources = cited.toList();
        }
      } catch (_) {
        // Retrieval failed (e.g. embedder unavailable) — answer without RAG,
        // but tell the user instead of failing silently.
        if (mounted) {
          setState(() => _notice =
              'Document search is unavailable right now — answering without '
              'your documents.');
        }
      }
    }
    assistant.sources = sources;

    // In assistant mode, keep the reply in the user's own language (the model
    // otherwise sometimes drifts to another language).
    if (_assistMode) systemContent = '$systemContent\n\n$_assistLangDirective';

    // Build the conversation: a system prompt followed by recent history
    // (excluding the still-empty assistant placeholder). History is trimmed
    // oldest-first so prompt + reply fit the model's 4096-token context —
    // otherwise a long chat silently overflows and degrades. ~3 chars/token is
    // a conservative multilingual estimate. A user turn that has an attached
    // image carries it in an `images` array (vision models).
    final history = _messages.where((m) => m != assistant).toList();
    final promptBudgetChars = (4096 - _maxTokens - 64).clamp(512, 1 << 20) * 3 -
        systemContent.length;
    final kept = <ChatMessage>[];
    var used = 0;
    for (final m in history.reversed) {
      used += m.text.length + 16;
      // Always keep the newest (current) user turn, whatever its size.
      if (kept.isNotEmpty && used > promptBudgetChars) break;
      kept.add(m);
    }
    final messagesJson = jsonEncode([
      {'role': 'system', 'content': systemContent},
      ...kept.reversed.map((m) {
        final msg = <String, dynamic>{'role': m.role, 'content': m.text};
        if (m.imagePath != null) msg['images'] = [m.imagePath];
        return msg;
      }),
    ]);
    final options = '{"max_tokens":$_maxTokens,"temperature":0.7}';

    final run = _engine.complete(messagesJson, optionsJson: options);
    run.tokens.listen(
      (token) {
        setState(() => assistant.text += token);
        _scrollToBottom();
      },
      onError: (e) {
        setState(() {
          assistant.text += '\n[error: $e]';
          _generating = false;
        });
      },
    );
    try {
      final stats = await run.stats;
      // Fall back to the authoritative full response if streaming was empty.
      final full = (stats['response'] as String?)?.trim();
      if (assistant.text.isEmpty && full != null && full.isNotEmpty) {
        setState(() => assistant.text = full);
      }
      final tps = stats['decode_tps'];
      setState(() {
        _generating = false;
        if (tps is num) _lastStats = '${tps.toStringAsFixed(1)} tok/s';
      });
      // Speak the reply when Eva was invoked as the device assistant.
      if (_assistMode) _speak(assistant.text);
    } catch (_) {
      setState(() => _generating = false);
    }
    if (assistant.text.isNotEmpty) _persistMessage(assistant);
    // The turn is done — let background indexing of the backlog continue.
    _indexer?.resume();
    _scrollToBottom();
  }

  Future<void> _newChat() async {
    if (_generating) return;
    await _engine.reset();
    setState(() {
      _convId = null; // next message starts a fresh stored conversation
      _messages.clear();
      _lastStats = null;
      _pendingImagePath = null;
    });
  }

  // ── Documents (RAG) ────────────────────────────────────────────────────────

  /// Lets the user attach a PDF/txt/md document, extract its text, and (re)build
  /// the retrieval index so Eva can answer questions about it.
  Future<void> _attachDocument() async {
    if (_docBusy || _generating) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: DocumentService.supportedExtensions,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _docBusy = true);
    try {
      final info = await _docs.addFile(path);
      _documents = await _docs.list();
      // Opening the pack starts the background indexer, which picks up this new
      // document (and resumes any interrupted ones) without blocking the UI.
      await _ensureRag();
      _indexer?.resume();
      unawaited(_indexer?.run() ?? Future.value());
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${info.name}" — indexing in background.')),
        );
      }
      _maybeNudgeDocModel();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add document: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _docBusy = false);
    }
  }

  /// Ensures the embedding model is downloaded + loaded and the RAG index for
  /// the current corpus location is open. Shows a progress dialog (the embedder
  /// download is ~200 MB the first time).
  Future<void> _ensureRag() async {
    if (_embedderReady && _rag != null) return;
    await _withProgressDialog('Setting up document search', (update) async {
      final dir = await _models.ensureInstalled(
          kEmbedderModel, (phase, p) => update(phase, p));
      update('Loading…', null);
      await _engine.loadEmbedder(dir);
      await _indexer?.stop();
      _rag?.close();
      _rag = await RagIndex.open(await _docs.corpusPath());
      _embedderReady = true;
    });
    // Compaction: after many document deletions the shards accumulate orphaned
    // vectors. When more than a quarter of the index (and a meaningful amount)
    // is orphans, drop the vectors and let the self-heal indexer rebuild.
    final rag = _rag!;
    final orphans = rag.orphanVectorCount;
    if (orphans > 500 && orphans * 4 > rag.vectorCount) {
      await rag.resetVectors();
    }
    // Start (or resume) indexing the backlog in the background — non-blocking,
    // so the chat stays usable and queries hit whatever is already indexed.
    _indexer ??= IndexingController(_docs, _engine.embedBatch)
      ..addListener(_onIndexerProgress);
    _indexer!.bind(_rag!);
    _indexer!.resume();
    unawaited(_indexer!.run());
  }

  void _onIndexerProgress() {
    if (!mounted) return;
    // Surface a failed indexing run once (it would otherwise be silent).
    final err = _indexer?.lastError;
    if (err != null && !identical(err, _seenIndexError)) {
      _seenIndexError = err;
      _notice = 'Document indexing hit a problem and will retry: $err';
    }
    setState(() {});
  }

  /// Suggests the stronger Qwen3 model for document Q&A when a weaker model is
  /// active (better synthesis of retrieved passages).
  void _maybeNudgeDocModel() {
    if (!mounted || _activeModelId == kDocQaModelId) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: const Text('Tip: Qwen3 1.7B gives better answers about documents.'),
      action: SnackBarAction(
        label: 'Use Qwen3',
        onPressed: () => _switchModel(kDocQaModelId),
      ),
    ));
  }

  Future<void> _switchModel(String id) async {
    if (id == _activeModelId) return;
    _activeModelId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_model', id);
    setState(() {
      _convId = null; // a model switch starts a fresh stored conversation
      _messages.clear();
      _lastStats = null;
    });
    await _prepareAndLoad();
  }

  /// Runs [work] while showing a modal progress dialog. [work] gets an updater
  /// `(phase, progress)`; progress is 0..1 or null for indeterminate.
  Future<void> _withProgressDialog(
    String title,
    Future<void> Function(void Function(String, double?)) work,
  ) async {
    if (!mounted) return;
    double? progress;
    String phase = 'Preparing…';
    StateSetter? setDlg;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (c, setState) {
          setDlg = setState;
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(phase),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
                if (progress != null) ...[
                  const SizedBox(height: 6),
                  Text('${(progress! * 100).toStringAsFixed(0)}%'),
                ],
              ],
            ),
          );
        },
      ),
    );
    try {
      await work((ph, p) {
        phase = ph;
        progress = p;
        setDlg?.call(() {});
      });
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// Toggles voice input. Starts/stops the streaming recognizer, feeding the
  /// live transcript into the message field. On first use it downloads the
  /// (offline) speech model.
  Future<void> _toggleVoice() async {
    // Already listening (on either engine) → stop.
    if (_voice.isListening || _systemVoice.isListening) {
      await _voice.stop();
      await _systemVoice.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    void onText(String text) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    }

    try {
      if (_voiceEngine == VoiceEngine.system) {
        // The phone's recognizer (many languages, incl. the system language).
        await _systemVoice.start(_voiceLocale, onText, onStopped: () {
          if (!mounted) return;
          setState(() {
            _listening = false;
            _input.text = _normalizeCase(_input.text);
            _input.selection =
                TextSelection.collapsed(offset: _input.text.length);
          });
        });
      } else {
        // The bundled offline English model — download it on first use.
        if (!await _ensureVoiceModel()) return;
        await _voice.start(onText);
      }
      if (mounted) setState(() => _listening = true);
    } catch (e) {
      if (mounted) {
        setState(() => _listening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice unavailable: $e')),
        );
      }
    }
  }

  /// Ensures the speech model is present, showing a progress dialog while it
  /// downloads on first use. Returns true if the model is ready.
  Future<bool> _ensureVoiceModel() async {
    if (await _voice.isModelInstalled()) return true;
    if (!mounted) return false;
    double? progress;
    String phase = 'Preparing…';
    StateSetter? setDlg;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (c, setState) {
          setDlg = setState;
          return AlertDialog(
            title: const Text('Setting up voice'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(phase),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
                if (progress != null) ...[
                  const SizedBox(height: 6),
                  Text('${(progress! * 100).toStringAsFixed(0)}%'),
                ],
              ],
            ),
          );
        },
      ),
    );
    var ok = false;
    try {
      await _voice.ensureModel((ph, p) {
        phase = ph;
        progress = p;
        setDlg?.call(() {});
      });
      await _voice.load();
      ok = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice setup failed: $e')),
        );
      }
    }
    if (mounted) Navigator.of(context).pop(); // close the progress dialog
    return ok;
  }

  /// Lets the user attach a photo (camera or gallery) to the next message.
  Future<void> _attachImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (picked != null) {
        setState(() => _pendingImagePath = picked.path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get image: $e')),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _phase == AppPhase.ready ? _buildDrawer() : null,
      appBar: AppBar(
        title: const Text('Eva'),
        actions: [
          if (_lastStats != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Text(_lastStats!, style: const TextStyle(fontSize: 12)),
              ),
            ),
          if (_phase == AppPhase.ready)
            IconButton(
              tooltip: 'New chat',
              onPressed: (_generating || _messages.isEmpty) ? null : _newChat,
              icon: const Icon(Icons.add_comment_outlined),
            ),
          if (_phase == AppPhase.ready)
            IconButton(
              tooltip: 'Models',
              onPressed: _generating ? null : _openSettings,
              icon: const Icon(Icons.tune),
            ),
        ],
        bottom: _indexingBanner(),
      ),
      body: switch (_phase) {
        AppPhase.ready => _buildChat(),
        AppPhase.error => _buildError(),
        _ => _buildLoading(),
      },
    );
  }

  /// A thin progress strip shown under the AppBar while the background indexer
  /// is working through the document backlog (null = nothing to show).
  PreferredSizeWidget? _indexingBanner() {
    final ix = _indexer;
    if (ix == null || !ix.isIndexing || ix.pending <= 0) return null;
    final label = ix.currentName == null
        ? 'Indexing ${ix.pending} document${ix.pending == 1 ? '' : 's'}…'
        : 'Indexing "${ix.currentName}" — ${ix.pending} left';
    return PreferredSize(
      preferredSize: const Size.fromHeight(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(label, style: const TextStyle(fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(value: _progress),
          const SizedBox(height: 16),
          Text(_statusText),
          if (_progress != null) ...[
            const SizedBox(height: 8),
            Text('${(_progress! * 100).toStringAsFixed(0)}%'),
          ],
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_statusText, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(onPressed: _bootstrap, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildChat() {
    return Column(
      children: [
        if (_updateTag != null) _updateBanner(),
        if (_notice != null) _noticeBanner(),
        Expanded(
          child: _messages.isEmpty
              ? const Center(child: Text('Say hello to start chatting.'))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) => _bubble(_messages[i]),
                ),
        ),
        const Divider(height: 1),
        if (_pendingImagePath != null) _pendingImagePreview(),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Attach a document',
                onPressed: (_generating || _docBusy) ? null : _attachDocument,
                icon: _docBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : _documents.isEmpty
                        ? const Icon(Icons.attach_file)
                        : Badge(
                            label: Text('${_documents.length}'),
                            child: const Icon(Icons.attach_file),
                          ),
              ),
              if (_visionActive)
                IconButton(
                  tooltip: 'Attach a photo',
                  onPressed: _generating ? null : _attachImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
              IconButton(
                tooltip: _listening ? 'Stop listening' : 'Speak',
                onPressed: _generating ? null : _toggleVoice,
                color: _listening ? Theme.of(context).colorScheme.error : null,
                icon: Icon(_listening ? Icons.mic : Icons.mic_none),
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: _visionActive ? 'Message or ask about a photo' : 'Message',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _generating ? null : _send,
                icon: _generating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Banner shown when a newer release than this build is published.
  Widget _updateBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.system_update_alt),
        title: Text('Eva $_updateTag is available.'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => launchUrl(Uri.parse(kReleasesUrl),
                  mode: LaunchMode.externalApplication),
              child: const Text('Get it'),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _updateTag = null),
            ),
          ],
        ),
      ),
    );
  }

  /// Dismissible notice for failures that would otherwise be invisible.
  Widget _noticeBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.info_outline, color: scheme.onErrorContainer),
        title: Text(_notice!,
            style: TextStyle(color: scheme.onErrorContainer, fontSize: 13)),
        trailing: IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => setState(() => _notice = null),
        ),
      ),
    );
  }

  Widget _pendingImagePreview() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(_pendingImagePath!),
              width: 56,
              height: 56,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Text('Photo attached')),
          IconButton(
            tooltip: 'Remove photo',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _pendingImagePath = null),
          ),
        ],
      ),
    );
  }

  Widget _bubble(ChatMessage m) {
    final isUser = m.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      decoration: BoxDecoration(
        color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      // User text is shown verbatim (with any attached photo above it);
      // assistant replies are rendered as markdown (bold, italics, lists, …).
      child: isUser
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (m.imagePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        File(m.imagePath!),
                        width: 180,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                if (m.text.isNotEmpty) Text(m.text),
              ],
            )
          : m.text.isEmpty
              ? const Text('…')
              : GptMarkdown(
                  m.text,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
    );

    if (isUser) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }
    // Assistant messages show Eva's avatar, like a chat with her.
    final sources = m.sources;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4, right: 8),
          child: CircleAvatar(
            radius: 18,
            backgroundImage: AssetImage('assets/eva.png'),
          ),
        ),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bubble,
              if (sources != null && sources.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6, top: 2, bottom: 4),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: -8,
                    children: [
                      for (final s in sources)
                        Chip(
                          avatar: const Icon(Icons.description_outlined, size: 14),
                          label: Text(s, style: const TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
