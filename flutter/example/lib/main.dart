import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:just_audio_background/just_audio_background.dart' hide TrackInfo;
import 'package:latlong2/latlong.dart';
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
import 'doc_meta.dart';
import 'docs_tab.dart';
import 'document_service.dart';
import 'download_service.dart';
import 'index_coordinator.dart';
import 'index_metrics.dart';
import 'images_tab.dart';
import 'inference_isolate.dart';
import 'music_tab.dart';
import 'intro_screen.dart';
import 'map_viewer_screen.dart';
import 'maps/map_ref.dart';
import 'maps/map_service.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'music_meta.dart';
import 'music_player.dart';
import 'music_service.dart';
import 'music_store.dart';
import 'doc_text_viewer_screen.dart';
import 'pdf_viewer_screen.dart';
import 'photo_service.dart';
import 'player_screen.dart';
import 'photo_store.dart';
import 'photos_screen.dart';
import 'rag_index.dart';
import 'reminder_service.dart';
import 'settings_screen.dart';
import 'setup_screen.dart';
import 'system_voice.dart';
import 'text_util.dart';
import 'update_check.dart';
import 'voice_service.dart';
import 'wikipedia_reader_screen.dart';
import 'wikipedia_service.dart';

const Color _seedColor = Color(0xFF2E7D32);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lets the download foreground service (keeps downloads alive when the app is
  // backgrounded / the phone is suspended) talk to the plugin.
  DownloadService.initCommunicationPort();
  // Enable background playback + a lock-screen / notification media control.
  // Best-effort: a failure here must never block the app from starting.
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'radio.geogram.eva.audio',
      androidNotificationChannelName: 'Eva playback',
      androidNotificationOngoing: true,
    );
  } catch (_) {}
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

enum AppPhase { intro, setup, preparing, downloading, loadingModel, ready, error }

class ChatMessage {
  ChatMessage(this.role, this.text, {this.imagePath, this.sources, this.photos});
  final String role; // 'user' or 'assistant'
  String text;
  // Absolute path of an image the user attached to this message (vision chat).
  final String? imagePath;
  // Document sources cited for this answer (RAG), shown under the bubble.
  List<Citation>? sources;
  // Photo-gallery results to show as a thumbnail grid (not persisted).
  List<PhotoInfo>? photos;
  // A map/location to show as an expandable tile under the answer.
  MapRef? map;
  // How long this answer took to produce (assistant turns), shown under it.
  Duration? elapsed;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
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
  int _tab = 0; // 0 chat · 1 images · 2 music · 3 docs
  late final TabController _tabController =
      TabController(length: 4, vsync: this)..addListener(_onTabChanged);
  late final PhotoService _photos = PhotoService(_docs);
  PhotoIndexController? _photoIndexer;
  late final MusicService _music = MusicService(_docs);
  MusicIndexController? _musicIndexer;
  late final MusicPlayer _player = MusicPlayer(_music)..addListener(_onPlayer);
  final WikipediaService _wiki = WikipediaService.instance;
  bool _listening = false;
  VoiceEngine _voiceEngine = VoiceEngine.fast;
  String _voiceLocale = '';
  List<DocumentInfo> _documents = const [];
  String _corpusLocation = '';
  RagIndex? _rag;
  IndexingController? _indexer;
  // Background phone-wide file discovery (separate from the embedding pass), so
  // a large library (e.g. thousands of PDFs) is fully found even when the app is
  // backgrounded or the phone is suspended — held alive by the foreground
  // service via the Indexer coordinator.
  DocumentScanController? _docScanner;
  bool _embedderReady = false;
  bool _docBusy = false;
  String _systemPrompt = kDefaultSystemPrompt;
  int _maxTokens = kDefaultMaxTokens;
  List<ModelSpec> _catalog = kBuiltinCatalog;
  String _activeModelId = kDefaultModelId;
  AppPhase _phase = AppPhase.preparing;
  String _statusText = 'Starting…';
  double? _progress;
  bool _generating = false;
  // What the assistant is doing before the first token streams (e.g.
  // "Searching your documents…", "Thinking…"), shown in the placeholder bubble.
  String _thinkingStage = '';
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
  // True while the embedder is being set up in the background (before indexing).
  bool _preparingDocs = false;
  // Photo content-understanding (vision) pass — runs only while charging+idle.
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySub;
  Timer? _captionTimer;
  // Periodic discovery of newly-added files (documents, photos, …).
  Timer? _rescanTimer;
  DateTime? _lastRescan;
  bool _charging = false;
  bool _appActive = true; // app is in the foreground (chat in active use)
  bool _captioning = false; // VLM loaded, captioning photos
  bool _captionStop = false;
  bool _forceCaption = false; // "Index now" override of the charging gate
  String? _modelBeforeCaption;
  // Unified Indexer panel: coordinates the three indexers + captioning, records
  // timing metrics, and holds a foreground service while anything is working.
  IndexMetrics? _indexMetrics;
  IndexCoordinator? _indexCoordinator;
  int _captionsDone = 0;
  bool _categorizing = false; // chat model labelling documents in the background
  bool _categorizeStop = false;
  bool _categorizingMusic = false; // chat model labelling music folders by genre
  bool _categorizeMusicStop = false;
  static const String _kCaptionModelId = 'lfm2-vl-450m-int4';
  // Terse prompt + small token cap keep each caption fast (the dominant cost is
  // generation length). Newest photos are captioned first, up to a cap; older
  // ones are filled in on demand when a query asks for that time range.
  static const String _captionPrompt =
      'In under 15 words: main subject, scene, any visible text, and whether it '
      'is a meme or screenshot.';
  static const int _kCaptionRecentCap = 2000;
  DateTime? _captionPriorityFrom; // a queried range to caption on demand
  DateTime? _captionPriorityTo;

  /// Whether the active model can see images (exposes the attach button).
  bool get _visionActive => modelById(_catalog, _activeModelId).isVision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupAssistant();
    _start();
    // Prepare the notifications/timezone backend so the first "remind me…" is
    // instant (best-effort; failures don't block the chat).
    ReminderService.instance.init().catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (_appActive) {
      // Back in the app: stop the photo-captioning pass immediately so the chat
      // is responsive (it competes for the model slot), and pick up new files.
      if (_captioning) _captionStop = true;
      _rescanForNewFiles();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Truly backgrounded: catch up on photo captioning + document
      // categorisation while the user is away (only runs if charging).
      _maybeStartCaptioning();
      _maybeCategorizeDocs();
      _maybeCategorizeMusic();
    }
  }

  /// First run shows the intro (permissions + downloads explainer, optional
  /// reusable models folder) before anything starts downloading.
  Future<void> _start() async {
    if (!await loadIntroSeen()) {
      setState(() => _phase = AppPhase.intro);
      return;
    }
    // First run (or an interrupted setup): let the user choose & download
    // models / Wikipedia, resuming any partial downloads.
    if (!await loadSetupDone()) {
      setState(() => _phase = AppPhase.setup);
      return;
    }
    await _bootstrap();
  }

  void _onTabChanged() {
    if (_tab != _tabController.index) {
      setState(() => _tab = _tabController.index);
      // Categorise in the foreground while the user views the relevant tab.
      if (_tab == 3) _maybeCategorizeDocs();
      if (_tab == 2) _maybeCategorizeMusic();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _input.dispose();
    _scroll.dispose();
    _voice.dispose();
    _systemVoice.dispose();
    _tts.stop();
    // Dispose the coordinator first: it holds listeners on the controllers below.
    _indexCoordinator?.dispose();
    _indexer?.removeListener(_onIndexerProgress);
    _indexer?.dispose();
    _docScanner?.pause();
    _docScanner?.dispose();
    _photoIndexer?.removeListener(_onPhotoProgress);
    _photoIndexer?.pause();
    _photoIndexer?.dispose();
    _musicIndexer?.removeListener(_onMusicProgress);
    _musicIndexer?.pause();
    _musicIndexer?.dispose();
    _player.removeListener(_onPlayer);
    _player.dispose();
    _captionStop = true;
    _batterySub?.cancel();
    _captionTimer?.cancel();
    _rescanTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
          )
            ..elapsed =
                m.elapsedMs != null ? Duration(milliseconds: m.elapsedMs!) : null
            ..map = m.mapJson == null
                ? null
                : MapRef.fromJson(
                    jsonDecode(m.mapJson!) as Map<String, dynamic>)));
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
              sources: m.sources,
              elapsedMs: m.elapsed?.inMilliseconds,
              mapJson: m.map == null ? null : jsonEncode(m.map!.toJson())));
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
    unawaited(_setupCaptioning());
    _setupPeriodicRescan();
    await _setupIndexCoordinator();
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
      // Hold a foreground service so this first download survives the user
      // switching apps or the phone sleeping mid-download.
      final path = await DownloadService.run(
        'Downloading ${spec.name}',
        () => _models.ensureInstalled(spec, (phase, progress) {
          if (!mounted) return;
          setState(() {
            _statusText = phase;
            _progress = progress;
          });
          DownloadService.update(progress == null
              ? phase
              : '$phase ${(progress * 100).round()}%');
        }),
      );
      await _loadModel(path);
      // Fully automatic: resume/continue indexing any document backlog in the
      // background, no user action required.
      unawaited(_autoIndexPending());
      _startDocumentScanning();
      _startPhotoIndexing();
      _startMusicIndexing();
      _maybeStartCaptioning();
      // Adopt a side-loaded Wikipedia .zim if one is present (no-op once set).
      unawaited(_wiki.discoverAndAdopt().catchError((_) => null));
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
          player: _player,
          indexCoordinator: _indexCoordinator,
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
      await _photoIndexer?.stop(); // photos.sqlite lives in the pack too
      await _musicIndexer?.stop(); // music.sqlite lives in the pack too
      _rag?.close();
      _rag = null;
      _embedderReady = false;
    }
    // Pick up a requested re-index of new photos / continue the gallery pass.
    _startDocumentScanning();
    _startPhotoIndexing();
    _startMusicIndexing();
    // Documents added in Settings (e.g. a bulk phone scan) start indexing in
    // the background right away — the chat stays usable meanwhile.
    if (docsNow.difference(docsBefore).isNotEmpty) {
      unawaited(_ensureRag().catchError((_) {}));
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
    if (text.isEmpty && imagePath != null) text = 'What is in this image?';
    // Time the whole turn (model swap + retrieval + generation) so we can show
    // how long the answer took.
    final turnTimer = Stopwatch()..start();
    // Pin this turn's language from the user's own words (keeps directive and
    // TTS voice consistent; falls back to the previous turn's when unsure).
    _turnLang = _detectLangBase(text) ?? _turnLang;

    // Show the user's message and a thinking placeholder immediately (also
    // claims the turn so the background vision pass can't restart). The model
    // swap below then happens while the placeholder is visible.
    final assistant = ChatMessage('assistant', '');
    final user = ChatMessage('user', text, imagePath: imagePath);
    _input.clear();
    setState(() {
      _messages.add(user);
      _messages.add(assistant);
      _generating = true;
      _thinkingStage = 'Thinking…';
      _pendingImagePath = null;
    });
    _persistMessage(user);
    _scrollToBottom();
    // Drop the keyboard so the reply has the full screen to be read.
    FocusManager.instance.primaryFocus?.unfocus();

    // Finalize dictation, hush TTS, and restore the chat model if the vision
    // pass had swapped in the caption model.
    if (_voice.isListening || _systemVoice.isListening) {
      await _voice.stop();
      await _systemVoice.stop();
      if (mounted) setState(() => _listening = false);
    }
    await _stopCaptioningForChat();
    await _stopCategorizingForChat();
    await _stopCategorizingMusicForChat();
    await _tts.stop();

    // "remind me … in 15 minutes / at 7pm" schedules an OS notification.
    if (imagePath == null && await _handleReminderCommand(text, assistant)) {
      setState(() => _generating = false);
      _persistMessage(assistant);
      _scrollToBottom();
      return;
    }

    // "play radio X" / "play <station>" streams an online station (checked
    // before music so a station name isn't searched in the local library).
    if (imagePath == null && await _handleRadioCommand(text, assistant)) {
      setState(() => _generating = false);
      _persistMessage(assistant);
      _scrollToBottom();
      return;
    }

    // "play <artist/song>" starts the in-app music player directly, no model.
    if (imagePath == null && await _handlePlayCommand(text, assistant)) {
      setState(() => _generating = false);
      _persistMessage(assistant);
      _scrollToBottom();
      return;
    }

    // Photo-gallery requests ("show my screenshots", "photos from last week")
    // are answered directly with a thumbnail grid instead of the language model.
    if (imagePath == null) {
      final pq = _parsePhotoQuery(text);
      if (pq != null && await _answerWithPhotos(pq, assistant)) {
        setState(() => _generating = false);
        _persistMessage(assistant);
        _scrollToBottom();
        return;
      }
    }

    // Map/location requests ("show me Lisbon on a map", "where is the Louvre")
    // are answered with an expandable map tile + live GPS dot, not the model.
    if (imagePath == null) {
      final mq = _parseMapQuery(text);
      if (mq != null && await _answerWithMap(mq, assistant)) {
        setState(() => _generating = false);
        _persistMessage(assistant);
        _scrollToBottom();
        return;
      }
    }

    var systemContent = _systemPrompt;
    List<Citation>? sources;
    // We combine three sources of knowledge in one answer: the user's own
    // documents (RAG), the offline Wikipedia, and the model's own training
    // knowledge. Each grounding source appends to [contextBuf] and contributes
    // citations; the model is told to synthesise all of them.
    final contextBuf = StringBuffer();
    final cites = <Citation>[];

    // 1) The user's own documents.
    if (_documents.isNotEmpty) {
      _setThinking('Searching your documents…');
      try {
        await _ensureRag();
        // Yield the embedder to this turn; query whatever is already indexed
        // (background indexing continues afterward). Resumed in the finally.
        await _indexer?.stop();
        final qvec = (await _engine.embedBatch([text])).first;
        final hits = await _rag!.query(queryVec: qvec, queryText: text, topK: 4);
        // Keep only passages that actually mention a query keyword. Semantic
        // retrieval always returns its top-N even for unrelated questions; left
        // in, those off-topic excerpts make the small model fixate on them and
        // answer "the documents don't mention X" instead of just answering.
        final keywords = significantWords(text);
        final relevant = keywords.isEmpty
            ? hits
            : hits
                .where((h) =>
                    keywords.any((k) => h.text.toLowerCase().contains(k)))
                .toList();
        if (relevant.isNotEmpty) {
          // Read paths fresh so citations are openable even right after a scan
          // backfilled them (the cached list may not have reloaded yet).
          final pathById = {
            for (final d in await _docs.list()) d.id: d.sourcePath
          };
          contextBuf.writeln("\n\nFrom the user's own documents:");
          final seen = <String>{};
          for (final h in relevant) {
            contextBuf.writeln('\n--- ${h.docName}'
                '${h.page != null ? ' (page ${h.page})' : ''} ---');
            contextBuf.writeln(h.text.trim());
            final label =
                h.page != null ? '${h.docName} (p.${h.page})' : h.docName;
            if (seen.add(label)) {
              cites.add(Citation(
                  label: label,
                  path: pathById[h.docId],
                  page: h.page,
                  docId: h.docId,
                  snippet: h.text.trim()));
            }
          }
        }
      } catch (_) {
        // Retrieval failed (e.g. embedder unavailable) — fall through and answer
        // from Wikipedia / the model's own knowledge.
      }
    }

    // 2) The offline Wikipedia (for general-knowledge questions with a match).
    _setThinking('Checking Wikipedia…');
    try {
      final wiki = await _wikiContext(text);
      if (wiki != null) {
        contextBuf.write(wiki.context);
        cites.add(wiki.cite);
      }
    } catch (_) {}

    // 3) Combine: a short directive in the system prompt; the actual reference
    // material is co-located with the question in the user turn below — small
    // models follow that far better than a large system-prompt dump (which made
    // this one just echo the topic word).
    final grounding = contextBuf.toString();
    if (grounding.isNotEmpty) {
      systemContent = "$_systemPrompt\n\nWhen the user's message includes "
          'reference material, use it together with your own knowledge to '
          'answer clearly, and mention the source (the document name, or '
          'Wikipedia) for any fact you take from it.';
      sources = cites;
    }
    assistant.sources = sources;
    _setThinking('Thinking…');

    // Music-library grounding: questions about songs, artists, albums, genres,
    // or lyrics are answered from the on-device music catalog.
    try {
      final mc = await _musicContext(text);
      if (mc != null) systemContent = '$systemContent$mc';
    } catch (_) {}

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
        // Co-locate the grounding with the current question so the model treats
        // it as material for THIS answer, not background it can ignore/echo.
        final content = (m == user && grounding.isNotEmpty)
            ? '$grounding\n\n---\nUsing the reference material above where it '
                'helps, answer this question: ${m.text}'
            : m.text;
        final msg = <String, dynamic>{'role': m.role, 'content': content};
        if (m.imagePath != null) msg['images'] = [m.imagePath];
        return msg;
      }),
    ]);
    // repetition_penalty well above the 1.1 default: this small model otherwise
    // loops, repeating whole paragraphs. top_p/top_k add sampling diversity.
    final options = '{"max_tokens":$_maxTokens,"temperature":0.7,'
        '"top_p":0.92,"top_k":40,"repetition_penalty":1.3}';

    final run = _engine.complete(messagesJson, optionsJson: options);
    run.tokens.listen(
      (token) {
        setState(() {
          assistant.text += token;
          _thinkingStage = ''; // first token arrived — drop the status line
        });
        _scrollToBottom();
      },
      onError: (e) {
        setState(() {
          assistant.text += '\n[error: $e]';
          _generating = false;
          _thinkingStage = '';
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
      turnTimer.stop();
      setState(() {
        _generating = false;
        _thinkingStage = '';
        assistant.elapsed = turnTimer.elapsed;
      });
      // Speak the reply when Eva was invoked as the device assistant.
      if (_assistMode) _speak(assistant.text);
    } catch (_) {
      turnTimer.stop();
      setState(() {
        _generating = false;
        _thinkingStage = '';
        assistant.elapsed = turnTimer.elapsed;
      });
    }
    if (assistant.text.isNotEmpty) _persistMessage(assistant);
    // The turn is done — let background indexing of the backlog continue.
    _indexer?.resume();
    _maybeStartCaptioning(); // resume the vision pass if idle + charging
    _scrollToBottom();
  }

  /// Interrupts a slow reply. The in-flight completion returns whatever it has
  /// so far and flips _generating off, freeing the input for the next message.
  void _stopGenerating() {
    if (!_generating) return;
    _engine.stopGeneration();
  }

  /// Updates the "what am I doing" line shown in the placeholder bubble before
  /// the first token streams.
  void _setThinking(String stage) {
    if (mounted) setState(() => _thinkingStage = stage);
  }

  Future<void> _newChat() async {
    if (_generating) return;
    await _engine.reset();
    // A send may have started during the await above; don't wipe its message.
    if (_generating) return;
    setState(() {
      _convId = null; // next message starts a fresh stored conversation
      _messages.clear();
      _pendingImagePath = null;
    });
  }

  // ── Documents (RAG) ────────────────────────────────────────────────────────

  /// Lets the user attach a document (PDF, Word/PowerPoint/Excel, EPUB, txt/md),
  /// extract its text, and (re)build the retrieval index so Eva can answer
  /// questions about it.
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
  /// Auto-starts (and resumes) document indexing on launch, with no taps and no
  /// modal. Cheaply checks the corpus catalog for a backlog first, so the
  /// ~0.2 GB embedder is only loaded when there is actually something to index —
  /// then the background indexer drains it and the app-bar banner shows progress.
  Future<void> _autoIndexPending() async {
    try {
      if (!await _docs.hasDocuments) return;
      // Opening the pack does NOT need the embedder — it only reads the catalog
      // + vector shards. Use it to detect a backlog before loading anything big.
      _rag ??= await RagIndex.open(await _docs.corpusPath());
      final indexed = _rag!.indexedDocIds;
      final pending =
          (await _docs.list()).where((d) => !indexed.contains(d.id)).length;
      if (pending == 0) return;
      await _ensureRag(modal: false);
    } catch (_) {/* will retry on next launch / interaction */}
  }

  Future<void> _ensureRag({bool modal = true}) async {
    if (_embedderReady && _rag != null) return;
    Future<void> load(void Function(String, double?) update) async {
      final dir = await _models.ensureInstalled(
          kEmbedderModel, (phase, p) => update(phase, p));
      update('Loading…', null);
      await _engine.loadEmbedder(dir);
      await _indexer?.stop();
      _rag?.close();
      _rag = await RagIndex.open(await _docs.corpusPath());
      _embedderReady = true;
    }

    if (modal) {
      await _withProgressDialog('Setting up document search', load);
    } else {
      // Background: a lightweight banner instead of a blocking dialog.
      if (mounted) setState(() => _preparingDocs = true);
      try {
        await load((_, _) {});
      } finally {
        if (mounted) setState(() => _preparingDocs = false);
      }
    }
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
    _indexCoordinator?.kick();
  }


  // ── Periodic discovery of newly-added files ─────────────────────────────────

  void _setupPeriodicRescan() {
    _rescanTimer =
        Timer.periodic(const Duration(minutes: 30), (_) => _rescanForNewFiles());
  }

  /// Re-discovers new files of every supported type (extensible — add a type by
  /// adding a line here). Cheap: each scan skips already-indexed and known-bad
  /// files. Throttled so frequent foregrounding doesn't thrash storage.
  Future<void> _rescanForNewFiles() async {
    if (_phase != AppPhase.ready) return;
    final now = DateTime.now();
    if (_lastRescan != null &&
        now.difference(_lastRescan!) < const Duration(minutes: 10)) {
      return;
    }
    _lastRescan = now;

    // Documents (PDF/text): re-walk the device for newly-added files in the
    // background (foreground-service backed, so it survives suspend); the
    // scanner queues new files and nudges the embedding pass as it goes.
    _startDocumentScanning();
    unawaited(_docScanner?.rescan() ?? Future.value());

    // Photos: re-walk the gallery for new images (the indexer skips known ones).
    await savePhotoScanDone(false);
    _startPhotoIndexing();

    // Music: re-walk for new audio files and fetch any missing lyrics.
    _startMusicIndexing();
    unawaited(_musicIndexer?.rescan() ?? Future.value());
  }

  /// Starts (or resumes) the continuous background gallery scan, which keeps
  /// running across launches until the whole gallery is catalogued.
  void _startPhotoIndexing() {
    _photoIndexer ??= PhotoIndexController(_photos)
      ..addListener(_onPhotoProgress);
    unawaited(_photoIndexer!.ensureRunning());
    _indexCoordinator?.kick();
  }

  /// Starts (or resumes) the continuous background music scan + lyrics pass.
  void _startMusicIndexing() {
    _musicIndexer ??= MusicIndexController(_music)
      ..addListener(_onMusicProgress);
    unawaited(_musicIndexer!.ensureRunning());
    _indexCoordinator?.kick();
  }

  /// Starts (or resumes) the continuous background document discovery walk,
  /// which keeps finding files across the whole device until the scan is
  /// complete — running under the foreground service so it survives the app
  /// being backgrounded or the phone suspended. Newly-discovered files are
  /// queued for embedding via [_onDocsDiscovered].
  void _startDocumentScanning() {
    _docScanner ??= DocumentScanController(_docs)
      ..addListener(_onDocScanProgress)
      ..onDocumentsAdded = _onDocsDiscovered;
    unawaited(_docScanner!.ensureRunning());
    _indexCoordinator?.kick();
  }

  void _onDocScanProgress() {
    if (mounted) setState(() {});
  }

  // Coalesces the discovery → embedding hand-off so a burst of newly-found files
  // kicks the embedder at most once per microtask.
  bool _docsDiscoverPending = false;

  /// Called by the document scanner as it queues newly-found files: refresh the
  /// list and make sure the embedding pass is running to drain the new backlog.
  void _onDocsDiscovered() {
    if (_docsDiscoverPending) return;
    _docsDiscoverPending = true;
    Future.microtask(() async {
      _docsDiscoverPending = false;
      try {
        _documents = await _docs.list();
      } catch (_) {}
      if (mounted) setState(() {});
      if (_embedderReady && _rag != null) {
        // Embedder already loaded: just nudge the indexer; its loop re-lists
        // documents each pass, so it picks up the new files.
        _indexer?.resume();
        unawaited(_indexer?.run() ?? Future.value());
      } else {
        // First backlog: load the embedder in the background and start indexing.
        unawaited(_ensureRag(modal: false).catchError((_) {}));
      }
      _indexCoordinator?.kick();
    });
  }

  void _onMusicProgress() {
    if (mounted) setState(() {});
  }

  /// Builds the unified Indexer coordinator. The indexer controllers are created
  /// lazily, so it reads them through getters and is kicked when work starts.
  Future<void> _setupIndexCoordinator() async {
    _indexMetrics = await IndexMetrics.load();
    _indexCoordinator = IndexCoordinator(
      metrics: _indexMetrics!,
      docIndexer: () => _indexer,
      docScanner: () => _docScanner,
      musicIndexer: () => _musicIndexer,
      photoIndexer: () => _photoIndexer,
      bridge: CaptionBridge(
        isCaptioning: () => _captioning,
        isCharging: () => _charging,
        captionCounts: _captionCounts,
        captionNow: _captionNow,
        pauseCaptioning: () => _captionStop = true,
      ),
    );
  }

  Future<({int pending, int done})> _captionCounts() async {
    final store = await _photos.openStore();
    try {
      return (pending: store.captionPendingCount, done: store.captionedCount);
    } finally {
      store.close();
    }
  }

  /// Force a captioning pass now, bypassing the charging gate (used by the
  /// Indexer panel's "Index now"). Cleared once the pass finishes.
  Future<void> _captionNow() async {
    _forceCaption = true;
    _maybeStartCaptioning();
  }

  // Words that signal the user is asking about their music library.
  static final RegExp _musicIntent = RegExp(
      r'\b(music|song|songs|track|tracks|artist|artists|band|bands|album|'
      r'albums|lyric|lyrics|genre|singer|singers|playlist|tune|tunes)\b',
      caseSensitive: false);

  /// If [text] is a music question and the catalog has matching tracks, returns
  /// a system-prompt augmentation grounding the answer on the user's library.
  /// Returns null otherwise (so non-music turns are untouched).
  Future<String?> _musicContext(String text) async {
    if (!_musicIntent.hasMatch(text)) return null;
    final store = await _music.openStore();
    try {
      if (store.count == 0) return null;
      // Prefer a focused full-text match; fall back to a library sample so
      // broad questions ("what music do I have?") still get grounded.
      var tracks = store.search(text, limit: 24);
      final scoped = tracks.isNotEmpty;
      if (tracks.isEmpty) tracks = store.query(limit: 24);
      if (tracks.isEmpty) return null;

      final buf = StringBuffer();
      buf.writeln(
          "\n\nThe user's on-device music library includes these tracks. Use "
          'them to answer questions about their music, artists, albums, genres, '
          'years, and lyrics. If the answer is not here, say you could not find '
          'it in their library.\n');
      var lyricsBudget = 3; // include lyric snippets only for the top few hits
      for (final t in tracks) {
        final parts = <String>[
          if (t.artist.isNotEmpty) 'Artist: ${t.artist}',
          'Title: ${t.title}',
          if (t.album.isNotEmpty) 'Album: ${t.album}',
          if (t.genre.isNotEmpty) 'Genre: ${t.genre}',
          if (t.year > 0) 'Year: ${t.year}',
        ];
        buf.writeln('- ${parts.join(', ')}');
        final lyr = (t.lyrics ?? '').trim();
        if (scoped && lyricsBudget > 0 && lyr.isNotEmpty) {
          final snip = lyr.replaceAll(RegExp(r'\s+'), ' ');
          buf.writeln('  Lyrics: '
              '${snip.length > 400 ? '${snip.substring(0, 400)}…' : snip}');
          lyricsBudget--;
        }
      }
      return buf.toString();
    } finally {
      store.close();
    }
  }

  void _onPhotoProgress() {
    if (mounted) setState(() {});
    _maybeStartCaptioning(); // frequent re-check while metadata indexing runs
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  /// Builds Wikipedia grounding for a factual turn: searches the offline ZIM and,
  /// if a confident article matches, returns its lead text + a citation. Uses a
  /// multilingual question heuristic (the confidence gate on the matched article
  /// is the real filter).
  Future<({String context, Citation cite})?> _wikiContext(String text) async {
    if (!_wiki.nativeAvailable) return null;
    if (!await loadWikipediaEnabled()) return null;
    if (!looksLikeQuestion(text)) return null;
    // Search on the meaningful keywords, not the raw question — the full-text
    // query parser does better with "gravity" than "What is gravity?".
    final kw = significantWords(text).join(' ');
    final hits = await _wiki.search(kw.isEmpty ? text : kw, k: 3);
    if (hits.isEmpty) return null;
    final top = hits.first;
    if (!_wiki.isConfident(text, top)) return null;
    final lead = await _wiki.leadText(top.path, maxChars: 3000);
    if (lead.trim().length < 40) return null;
    final buf = StringBuffer()
      ..writeln('\n\n--- Wikipedia article: "${top.title}" ---')
      ..writeln(lead);
    // A clean snippet (strip the FTS <b> markers) lets the reader scroll to the
    // cited passage.
    final snippet = top.snippet.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    return (
      context: buf.toString(),
      cite: Citation(
          label: 'Wikipedia: ${top.title}',
          wikiPath: top.path,
          snippet: snippet.isEmpty ? null : snippet),
    );
  }

  // A leading "play" verb (EN/PT) that starts the in-app player.
  static final RegExp _playVerb = RegExp(
      r'^\s*(play|put\s+on|toca(?:r)?|p[õo]e|ouvir|coloca(?:r)?)\b',
      caseSensitive: false);
  // Filler stripped from the request to leave just the artist/song/genre.
  static const Set<String> _playFiller = {
    'me', 'some', 'a', 'an', 'the', 'song', 'songs', 'music', 'track', 'tracks',
    'tune', 'tunes', 'by', 'from', 'for', 'please', 'something', 'anything',
    'of', 'my', 'uma', 'umas', 'uns', 'músicas', 'musicas', 'música', 'musica',
    'canção', 'cancao', 'canções', 'cancoes', 'do', 'da', 'de', 'algo',
  };

  /// Handles "play …" by starting the music player. Returns true when the turn
  /// was a play request (so [_send] stops before calling the model).
  Future<bool> _handlePlayCommand(String text, ChatMessage assistant) async {
    if (!_playVerb.hasMatch(text)) return false;
    // Strip the verb, then drop filler words to isolate the query.
    final rest = text.replaceFirst(_playVerb, '').trim();
    final words = RegExp(r'[\p{L}\p{N}&]+', unicode: true)
        .allMatches(rest)
        .map((m) => m.group(0)!)
        .toList();
    final meaningful =
        words.where((w) => !_playFiller.contains(w.toLowerCase())).toList();
    final query = meaningful.join(' ');

    List<TrackInfo> tracks;
    try {
      tracks = await _music.resolvePlay(query);
    } catch (_) {
      tracks = const [];
    }

    if (tracks.isEmpty) {
      final indexed = await _music.trackCount();
      setState(() {
        assistant.text = indexed == 0
            ? "I don't have any music indexed yet. Once your audio files are "
                'scanned (Settings → Music), I can play them.'
            : query.isEmpty
                ? "I couldn't find anything to play in your music library."
                : 'I could not find "$query" in your music library.';
      });
      return true;
    }

    await _player.playQueue(tracks);
    final first = tracks.first;
    final more = tracks.length - 1;
    setState(() {
      assistant.text = query.isEmpty
          ? '▶ Playing your music — starting with ${first.label}'
              '${more > 0 ? ' and $more more.' : '.'}'
          : '▶ Now playing ${first.label}'
              '${more > 0 ? ' and $more more from "$query".' : '.'}';
    });
    return true;
  }

  // ── Web radio ───────────────────────────────────────────────────────────────

  /// Handles "play radio …" / "play [station]" by streaming a saved station.
  /// Returns true (skipping music + the model) when it matched a station.
  Future<bool> _handleRadioCommand(String text, ChatMessage assistant) async {
    final t = text.toLowerCase();
    final hasPlayVerb = _playVerb.hasMatch(text);
    final mentionsRadio = RegExp(r'\bradios?\b|\br[áa]dios?\b').hasMatch(t);
    // Only consider radio when the user said "radio" or used a play verb; a bare
    // sentence shouldn't accidentally start a stream.
    if (!mentionsRadio && !hasPlayVerb) return false;

    final stations = await loadRadioStations();
    if (stations.isEmpty) return false;

    // 1) Direct name match anywhere in the message (e.g. "play Groove Salad").
    RadioStation? match;
    for (final s in stations) {
      if (s.name.isNotEmpty && t.contains(s.name.toLowerCase())) {
        match = s;
        break;
      }
    }
    // 2) "play radio <something>" → fuzzy match the trailing words to a station.
    if (match == null && mentionsRadio) {
      final after = t.split(RegExp(r'\br[áa]dios?\b')).last.trim();
      final words = after
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 2)
          .toList();
      if (words.isNotEmpty) {
        for (final s in stations) {
          final name = s.name.toLowerCase();
          final genre = s.genre.toLowerCase();
          if (words.any((w) => name.contains(w) || genre.contains(w))) {
            match = s;
            break;
          }
        }
      }
      // Plain "play radio" with no usable name → first station.
      match ??= stations.first;
    }
    if (match == null) return false;

    await incrementRadioPlay(match.url); // count it so favourites surface
    await _player.playRadio(match.name, match.url);
    setState(() {
      assistant.text = '▶ Tuning in to ${match!.name} — live radio.';
    });
    return true;
  }

  // ── Timed reminders ─────────────────────────────────────────────────────────

  // Words that signal a reminder/alarm/timer request (EN + PT).
  static final RegExp _reminderTrigger = RegExp(
      r'\b(remind me|reminder|set (an? )?(reminder|alarm|timer)|wake me|'
      r'alarm|timer|lembra-?me|lembrete|alarme|despertar|temporizador)\b',
      caseSensitive: false);

  /// Parses a reminder request into the time it should fire and the text to
  /// show. Returns null if no time could be understood.
  ({DateTime when, String what})? _parseReminder(String text) {
    final t = text.toLowerCase();
    if (!_reminderTrigger.hasMatch(t)) return null;

    final now = DateTime.now();
    DateTime? when;
    String? timePhrase; // the matched time substring, removed from "what"

    // Relative: "in 15 minutes", "em 15 minutos", "daqui a 2 horas",
    // "15 minutes from now", "after 30 min".
    final relUnit = r'(seconds?|secs?|segundos?|minutes?|mins?|minutos?|'
        r'hours?|hrs?|horas?|days?|dias?)';
    final rel = RegExp('\\b(?:in|em|daqui a|after|ap[oó]s)\\s+(\\d+)\\s*$relUnit')
            .firstMatch(t) ??
        RegExp('\\b(\\d+)\\s*$relUnit\\s+(?:from now|a partir de agora)\\b')
            .firstMatch(t);
    // "in half an hour" / "in an hour" / "in a minute".
    final relWordy = RegExp(
            r'\bin\s+(half\s+an?\s+hour|an?\s+hour|a\s+minute|a\s+few\s+minutes)\b')
        .firstMatch(t);

    if (rel != null) {
      final n = int.tryParse(rel.group(1)!) ?? 0;
      final unit = rel.group(2)!;
      when = now.add(_durationFor(n, unit));
      timePhrase = rel.group(0);
    } else if (relWordy != null) {
      final phrase = relWordy.group(1)!;
      Duration d;
      if (phrase.startsWith('half')) {
        d = const Duration(minutes: 30);
      } else if (phrase.contains('hour')) {
        d = const Duration(hours: 1);
      } else if (phrase.contains('few')) {
        d = const Duration(minutes: 5);
      } else {
        d = const Duration(minutes: 1);
      }
      when = now.add(d);
      timePhrase = relWordy.group(0);
    } else {
      // Absolute: "at 7pm", "at 15:30", "às 19h", "às 7:45".
      final abs = RegExp(
              r'\b(?:at|às|as|@)\s+(\d{1,2})(?:[:h.](\d{2}))?\s*(am|pm)?\b')
          .firstMatch(t);
      if (abs != null) {
        var hour = int.tryParse(abs.group(1)!) ?? 0;
        final minute = int.tryParse(abs.group(2) ?? '0') ?? 0;
        final ampm = abs.group(3);
        if (ampm == 'pm' && hour < 12) hour += 12;
        if (ampm == 'am' && hour == 12) hour = 0;
        if (hour > 23 || minute > 59) return null;
        var candidate = DateTime(now.year, now.month, now.day, hour, minute);
        // If that time already passed today, schedule it for tomorrow.
        if (!candidate.isAfter(now)) {
          candidate = candidate.add(const Duration(days: 1));
        }
        when = candidate;
        timePhrase = abs.group(0);
      }
    }

    if (when == null) return null;

    // Build the "what": strip the trigger, the time phrase and leading
    // connectors ("to", "that", "para", "de", "para que").
    var what = text;
    what = what.replaceAll(_reminderTrigger, ' ');
    if (timePhrase != null) {
      what = what.toLowerCase().replaceAll(timePhrase, ' ');
    }
    what = what
        .replaceAll(RegExp(r'^[\s,]*(to|that|para que|para|de|of)\b',
            caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (what.isEmpty) what = 'Reminder';
    // Capitalise the first letter for a tidy notification.
    what = what[0].toUpperCase() + what.substring(1);
    return (when: when, what: what);
  }

  Duration _durationFor(int n, String unit) {
    if (unit.startsWith('sec') || unit.startsWith('seg')) {
      return Duration(seconds: n);
    }
    if (unit.startsWith('hour') || unit.startsWith('hr') || unit.startsWith('hora')) {
      return Duration(hours: n);
    }
    if (unit.startsWith('day') || unit.startsWith('dia')) {
      return Duration(days: n);
    }
    return Duration(minutes: n); // minutes default
  }

  /// Schedules a reminder when [text] is a reminder request. Returns true (so
  /// [_send] skips the model) when handled.
  Future<bool> _handleReminderCommand(String text, ChatMessage assistant) async {
    final parsed = _parseReminder(text);
    if (parsed == null) return false;

    final ok = await ReminderService.instance.requestPermissions();
    if (!ok) {
      setState(() {
        assistant.text = 'I can set that, but notifications are turned off. '
            'Enable them in Settings → Reminders and try again.';
      });
      return true;
    }

    final id = (parsed.when.millisecondsSinceEpoch ~/ 1000) % 2000000000;
    try {
      await ReminderService.instance
          .schedule(parsed.when, 'Eva reminder', parsed.what, id: id);
      // Persist (and prune past ones) so the record survives a restart.
      final list = await loadReminders();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      list.removeWhere((r) => r.whenMs < nowMs);
      list.add(ReminderItem(
          id: id, text: parsed.what, whenMs: parsed.when.millisecondsSinceEpoch));
      await saveReminders(list);
    } catch (_) {
      setState(() {
        assistant.text =
            "I couldn't schedule that reminder just now. Please try again.";
      });
      return true;
    }

    setState(() {
      assistant.text =
          '⏰ Reminder set for ${_friendlyWhen(parsed.when)}: ${parsed.what}';
    });
    return true;
  }

  /// A human phrasing of when a reminder fires, e.g. "in 15 minutes (14:30)"
  /// or "today at 19:00" / "tomorrow at 07:30".
  String _friendlyWhen(DateTime when) {
    final now = DateTime.now();
    final diff = when.difference(now);
    String hhmm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (diff.inMinutes < 1) return 'in under a minute (${hhmm(when)})';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return 'in $m minute${m == 1 ? '' : 's'} (${hhmm(when)})';
    }
    if (diff.inHours < 24 && when.day == now.day) {
      return 'today at ${hhmm(when)}';
    }
    final tomorrow = now.add(const Duration(days: 1));
    if (when.day == tomorrow.day && when.month == tomorrow.month) {
      return 'tomorrow at ${hhmm(when)}';
    }
    return 'on ${when.day}/${when.month} at ${hhmm(when)}';
  }

  // ── Photo content understanding (vision caption pass) ───────────────────────

  /// On external power = charging, full, or plugged-in-but-full (not draining).
  bool _onPower(BatteryState s) =>
      s == BatteryState.charging ||
      s == BatteryState.full ||
      s == BatteryState.connectedNotCharging;

  /// Watches the charger so captioning only runs while plugged in (gentle on
  /// battery, per the chosen policy).
  Future<void> _setupCaptioning() async {
    try {
      _charging = _onPower(await _battery.batteryState);
      if (_charging) _maybeStartCaptioning(); // already plugged in at launch
    } catch (_) {}
    _batterySub = _battery.onBatteryStateChanged.listen((s) {
      _charging = _onPower(s);
      if (!_charging) _captionStop = true; // unplugged — yield the engine back
    });
    // Reliable re-check: triggers (metadata/doc notifications, charge events)
    // can be sparse during a long single embed, so poll the gate periodically.
    _captionTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_charging) _maybeStartCaptioning();
      // Gate internally: run while charging+idle, or while viewing the relevant
      // tab in the foreground.
      _maybeCategorizeDocs();
      _maybeCategorizeMusic();
    });
  }

  /// Starts the vision pass when idle + charging and there's a backlog.
  void _maybeStartCaptioning() {
    // Captioning swaps the (idle) chat-model slot to the vision model; document
    // indexing uses the separate embedder slot, so the two run concurrently.
    if (_captioning ||
        _phase != AppPhase.ready ||
        _generating ||
        _preparingDocs ||
        (!_forceCaption && (!_charging || _appActive))) {
      return;
    }
    unawaited(_runCaptioning());
  }

  Future<void> _runCaptioning() async {
    if (_captioning ||
        _generating ||
        (!_forceCaption && (!_charging || _appActive))) {
      return;
    }
    // Anything to do?
    final probe = await _photos.openStore();
    int pending;
    try {
      pending = probe.captionPendingCount;
    } finally {
      probe.close();
    }
    if (pending == 0) return;

    _captioning = true;
    _captionStop = false;
    _modelBeforeCaption = _activeModelId;
    if (mounted) setState(() {});
    _indexCoordinator?.kick();
    // Pause only the metadata photo indexer (it writes photos.sqlite too);
    // document indexing keeps running on the separate embedder slot.
    await _photoIndexer?.stop();
    final tmp = File('${(await getTemporaryDirectory()).path}/caption_thumb.jpg');
    try {
      final vlm = modelById(_catalog, _kCaptionModelId);
      final dir = await _models.ensureInstalled(vlm, (_, _) {});
      await _engine.initModel(dir); // swaps the chat model out
      while (!_captionStop &&
          !_generating &&
          (_forceCaption || (_charging && !_appActive))) {
        final store = await _photos.openStore();
        List<PhotoInfo> batch;
        try {
          // On-demand: caption a queried range first; otherwise caption the
          // newest photos up to the cap (older ones wait for a query).
          if (_captionPriorityFrom != null || _captionPriorityTo != null) {
            batch = store.pendingCaption(
                from: _captionPriorityFrom, to: _captionPriorityTo, limit: 8);
            if (batch.isEmpty) {
              _captionPriorityFrom = null;
              _captionPriorityTo = null;
            }
          } else if (_captionsDone >= _kCaptionRecentCap) {
            batch = const []; // captioned enough newest photos this session
          } else {
            batch = store.pendingCaption(limit: 8);
          }
        } finally {
          store.close();
        }
        if (batch.isEmpty) {
          // Priority range just cleared — loop once more for general backlog.
          if (_captionPriorityFrom != null || _captionPriorityTo != null) {
            continue;
          }
          break;
        }
        for (final p in batch) {
          if (_captionStop ||
              _generating ||
              (!_forceCaption && (_charging == false || _appActive))) {
            break;
          }
          final cap = await _captionOne(p, tmp);
          final s2 = await _photos.openStore();
          try {
            s2.setCaption(p.id, cap ?? ''); // empty marks it done, won't retry
          } finally {
            s2.close();
          }
          if (cap != null && cap.isNotEmpty) _captionsDone++;
          if (mounted) setState(() {});
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    } catch (_) {
      // transient — retry next charging window
    } finally {
      await _restoreChatModel();
      _captioning = false;
      _forceCaption = false;
      if (mounted) setState(() {});
      // Resume the metadata photo indexer we paused.
      _startPhotoIndexing();
    }
  }

  Future<String?> _captionOne(PhotoInfo p, File tmp) async {
    if (p.thumb == null) return null;
    try {
      await tmp.writeAsBytes(p.thumb!, flush: true);
      final messages = jsonEncode([
        {'role': 'user', 'content': _captionPrompt, 'images': [tmp.path]}
      ]);
      final run = _engine.complete(messages,
          optionsJson: '{"max_tokens":32,"temperature":0.2}');
      final buf = StringBuffer();
      run.tokens.listen(buf.write, onError: (_) {});
      final stats = await run.stats;
      final full = (stats['response'] as String?)?.trim();
      final text = (full != null && full.isNotEmpty) ? full : buf.toString().trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  // ── Background document categorisation (LLM) ────────────────────────────────

  static const String _categorizePrompt =
      'You are a librarian. Classify the document excerpt into a short, broad '
      'top-level category (a genre like Fiction, Science, History, Finance, '
      'Technology, Cooking, Health, Law, Religion, Reference, Manual, Personal), '
      'a more specific subcategory, and up to 4 short topic tags. '
      'Reply ONLY with compact JSON: '
      '{"category":"...","subcategory":"...","tags":["...","..."]}';

  /// Runs the chat model over not-yet-categorised documents — both while idle +
  /// charging in the background AND while the user is viewing the Docs tab (so
  /// they see progress) — labelling each with a genre/subcategory/tags. Reuses
  /// the already-extracted text from the corpus database (no re-reading files)
  /// and the already-loaded chat model (no swap).
  void _maybeCategorizeDocs() {
    if (_categorizing ||
        _categorizingMusic ||
        _captioning ||
        _phase != AppPhase.ready ||
        _generating ||
        _preparingDocs) {
      return;
    }
    if (!_shouldCategorize) return;
    unawaited(_runDocCategorization());
  }

  // Categorise in the background when charging + idle, or in the foreground
  // while the user is looking at the Docs tab.
  bool get _shouldCategorize =>
      (_charging && !_appActive) || (_appActive && _tab == 3);

  Future<void> _runDocCategorization() async {
    if (_categorizing) return;
    _categorizing = true;
    _categorizeStop = false;
    try {
      final docs = await _docs.list();
      if (docs.isEmpty) return;
      final meta = await DocMetaStore.all();
      final todo =
          docs.where((d) => !(meta[d.id]?.categorized ?? false)).toList();
      if (todo.isEmpty) return;
      var done = 0;
      docCategorizeProgress.value = (done: 0, total: todo.length);
      for (final d in todo) {
        if (_categorizeStop || _generating || !_shouldCategorize) break;
        final text = await _docs.readText(d.id); // already-extracted text
        final cat = await _categorizeOne('${d.name}\n\n$text');
        // On a parse miss, file under "General" (still marks it done so the
        // pass doesn't loop on it).
        await DocMetaStore.setCategory(
            d.id, cat?.$1 ?? 'General', cat?.$2 ?? '', cat?.$3 ?? const []);
        done++;
        docCategorizeProgress.value = (done: done, total: todo.length);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    } catch (_) {
      // transient — retry next window
    } finally {
      docCategorizeProgress.value = (done: 0, total: 0);
      _categorizing = false;
    }
  }

  /// Stops the categorisation pass and waits for the in-flight document to
  /// finish, so a chat turn can claim the model cleanly.
  Future<void> _stopCategorizingForChat() async {
    if (!_categorizing) return;
    _categorizeStop = true;
    for (var i = 0; i < 60 && _categorizing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<(String, String, List<String>)?> _categorizeOne(String docText) async {
    try {
      final excerpt =
          docText.length > 2000 ? docText.substring(0, 2000) : docText;
      final messages = jsonEncode([
        {'role': 'system', 'content': _categorizePrompt},
        {'role': 'user', 'content': excerpt},
      ]);
      final run = _engine.complete(messages,
          optionsJson: '{"max_tokens":120,"temperature":0.1}');
      final buf = StringBuffer();
      run.tokens.listen(buf.write, onError: (_) {});
      final stats = await run.stats;
      final full = (stats['response'] as String?)?.trim();
      final text =
          (full != null && full.isNotEmpty) ? full : buf.toString().trim();
      final m = RegExp(r'\{.*\}', dotAll: true).firstMatch(text);
      if (m == null) return null;
      final j = jsonDecode(m.group(0)!) as Map<String, dynamic>;
      String s(Object? v) => (v ?? '').toString().trim();
      final cat = s(j['category']);
      final sub = s(j['subcategory']);
      final tags = (j['tags'] as List?)
              ?.map((e) => e.toString().trim())
              .where((t) => t.isNotEmpty)
              .take(4)
              .toList() ??
          const <String>[];
      if (cat.isEmpty) return null;
      return (cat, sub, tags);
    } catch (_) {
      return null;
    }
  }

  // ── Background music-folder categorisation (LLM) ─────────────────────────────

  static const String _musicGenrePrompt =
      'You are a music librarian. Given a music folder (usually an album or an '
      'artist collection — a folder with under ~20 tracks is typically one '
      "album), use your knowledge of the artist and tracks to assign a broad "
      'genre and a specific subgenre. Reply ONLY with compact JSON: '
      '{"genre":"...","subgenre":"..."}';

  void _maybeCategorizeMusic() {
    if (_categorizingMusic ||
        _categorizing ||
        _captioning ||
        _phase != AppPhase.ready ||
        _generating ||
        _preparingDocs) {
      return;
    }
    // Background while charging+idle, or foreground while viewing the Music tab.
    final ok = (_charging && !_appActive) || (_appActive && _tab == 2);
    if (!ok) return;
    unawaited(_runMusicCategorization());
  }

  bool get _shouldCategorizeMusic =>
      (_charging && !_appActive) || (_appActive && _tab == 2);

  Future<void> _runMusicCategorization() async {
    if (_categorizingMusic) return;
    _categorizingMusic = true;
    _categorizeMusicStop = false;
    final store = await _music.openStore();
    try {
      final folders = store.folders(limit: 1000);
      if (folders.isEmpty) return;
      final meta = await MusicMetaStore.all();
      final todo =
          folders.where((f) => !(meta[f.name]?.categorized ?? false)).toList();
      if (todo.isEmpty) return;
      var done = 0;
      musicCategorizeProgress.value = (done: 0, total: todo.length);
      for (final f in todo) {
        if (_categorizeMusicStop || _generating || !_shouldCategorizeMusic) break;
        final tracks = store.byFolder(f.name, limit: 60);
        final g = await _categorizeMusicFolder(f.name, tracks);
        await MusicMetaStore.setGenre(f.name, g?.$1 ?? 'Other', g?.$2 ?? '');
        done++;
        musicCategorizeProgress.value = (done: done, total: todo.length);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    } catch (_) {
      // transient — retry next window
    } finally {
      musicCategorizeProgress.value = (done: 0, total: 0);
      store.close();
      _categorizingMusic = false;
    }
  }

  Future<(String, String)?> _categorizeMusicFolder(
      String folder, List<TrackInfo> tracks) async {
    try {
      // Build a compact summary: dominant artist(s), album(s), some titles.
      final artists = <String, int>{};
      final albums = <String>{};
      for (final t in tracks) {
        if (t.artist.isNotEmpty) artists[t.artist] = (artists[t.artist] ?? 0) + 1;
        if (t.album.isNotEmpty) albums.add(t.album);
      }
      final topArtists = (artists.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .take(3)
          .map((e) => e.key)
          .join(', ');
      final titles = tracks.take(12).map((t) => t.title).where((s) => s.isNotEmpty).join('; ');
      final summary = [
        'Folder: $folder',
        if (topArtists.isNotEmpty) 'Artist(s): $topArtists',
        if (albums.isNotEmpty) 'Album(s): ${albums.take(3).join(', ')}',
        'Tracks (${tracks.length}): $titles',
      ].join('\n');
      final messages = jsonEncode([
        {'role': 'system', 'content': _musicGenrePrompt},
        {'role': 'user', 'content': summary},
      ]);
      final run = _engine.complete(messages,
          optionsJson: '{"max_tokens":60,"temperature":0.1}');
      final buf = StringBuffer();
      run.tokens.listen(buf.write, onError: (_) {});
      final stats = await run.stats;
      final full = (stats['response'] as String?)?.trim();
      final text =
          (full != null && full.isNotEmpty) ? full : buf.toString().trim();
      final m = RegExp(r'\{.*\}', dotAll: true).firstMatch(text);
      if (m == null) return null;
      final j = jsonDecode(m.group(0)!) as Map<String, dynamic>;
      String s(Object? v) => (v ?? '').toString().trim();
      final genre = s(j['genre']);
      final sub = s(j['subgenre']);
      if (genre.isEmpty) return null;
      return (genre, sub);
    } catch (_) {
      return null;
    }
  }

  Future<void> _stopCategorizingMusicForChat() async {
    if (!_categorizingMusic) return;
    _categorizeMusicStop = true;
    for (var i = 0; i < 60 && _categorizingMusic; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Reloads the user's chat model after a caption session.
  Future<void> _restoreChatModel() async {
    final id = _modelBeforeCaption;
    _modelBeforeCaption = null;
    if (id == null) return;
    try {
      final spec = modelById(_catalog, id);
      final dir = await _models.ensureInstalled(spec, (_, _) {});
      await _engine.initModel(dir);
    } catch (_) {}
  }

  /// Ensures the chat model is loaded before a chat turn (caption mode may have
  /// swapped in the vision model). Returns once the chat model is back.
  Future<void> _stopCaptioningForChat() async {
    if (!_captioning) return;
    _captionStop = true;
    // Wait for the caption loop to finish its in-flight inference AND restore the
    // chat model (it sets _captioning=false only after _restoreChatModel). A
    // single VLM caption can take several seconds, so allow generous time —
    // otherwise the turn would run on the vision model and answer with garbage.
    var waited = 0;
    while (_captioning && waited < 600) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      waited++;
    }
  }

  void _onIndexerProgress() {
    if (!mounted) return;
    // When the document backlog drains, the engine is free for the vision pass.
    if (_indexer?.isIndexing == false) _maybeStartCaptioning();
    // Per-document failures (skipped, not fatal) are surfaced quietly in the
    // Settings panel — no need to interrupt the chat with a banner about them.
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
    if (_phase == AppPhase.intro) {
      return IntroScreen(onDone: () => setState(() => _phase = AppPhase.setup));
    }
    if (_phase == AppPhase.setup) {
      return SetupScreen(
        manager: _models,
        onDone: () {
          setState(() => _phase = AppPhase.preparing);
          _bootstrap();
        },
      );
    }
    if (_phase != AppPhase.ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('Eva')),
        body: _phase == AppPhase.error ? _buildError() : _buildLoading(),
      );
    }

    return Scaffold(
      drawer: _tab == 0 ? _buildDrawer() : null,
      appBar: AppBar(
        title: const Text('Eva'),
        actions: [
          if (_tab == 0)
            IconButton(
              tooltip: 'New chat',
              onPressed: (_generating || _messages.isEmpty) ? null : _newChat,
              icon: const Icon(Icons.add_comment_outlined),
            ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _generating ? null : _openSettings,
            icon: const Icon(Icons.tune),
          ),
        ],
        // The section tabs sit under the title (not at the bottom, where they
        // crowded the message input).
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.chat_bubble_outline), text: 'Chat'),
            Tab(icon: Icon(Icons.photo_library_outlined), text: 'Images'),
            Tab(icon: Icon(Icons.library_music_outlined), text: 'Music'),
            Tab(icon: Icon(Icons.menu_book_outlined), text: 'Docs'),
          ],
        ),
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          _buildChat(),
          ImagesTab(photos: _photos),
          MusicTab(music: _music, player: _player),
          DocsTab(docs: _docs),
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

  /// Friendly empty state with Eva's avatar instead of a bare line of text.
  Widget _emptyState() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(
              radius: 40,
              backgroundImage: AssetImage('assets/eva_avatar.png'),
            ),
            const SizedBox(height: 16),
            Text('Hi, I\'m Eva',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Ask me anything, or about your documents, photos, music and '
              'offline Wikipedia.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
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
              ? _emptyState()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) => _bubble(_messages[i]),
                ),
        ),
        if (_player.hasMedia) _nowPlayingBar(),
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
                    : const Icon(Icons.attach_file),
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
              // While generating, the button becomes a larger, prominent Stop
              // control (a clear ring + square) so it's easy to spot and tap to
              // interrupt a slow reply; otherwise it sends.
              IconButton.filled(
                tooltip: _generating ? 'Stop' : 'Send',
                style: _generating
                    ? IconButton.styleFrom(
                        minimumSize: const Size(52, 52),
                        backgroundColor:
                            Theme.of(context).colorScheme.errorContainer,
                        foregroundColor:
                            Theme.of(context).colorScheme.onErrorContainer,
                      )
                    : null,
                onPressed: _generating ? _stopGenerating : _send,
                icon: _generating
                    ? SizedBox(
                        width: 34,
                        height: 34,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                            const Icon(Icons.stop, size: 22),
                          ],
                        ),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Compact now-playing bar with transport controls, shown above the input
  /// whenever a track is loaded in the in-app player.
  void _openPlayer() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(player: _player, music: _music),
    ));
  }

  Widget _nowPlayingBar() {
    final scheme = Theme.of(context).colorScheme;
    final radio = _player.isRadio;
    final t = _player.current;
    if (!radio && t == null) return const SizedBox.shrink();
    // Title/subtitle differ for a live radio stream vs a local track queue.
    final title = radio
        ? (_player.radioName ?? 'Radio')
        : (t!.title.isNotEmpty ? t.title : t.path.split('/').last);
    final subtitle = radio
        ? 'Live radio'
        : (t!.artist.isNotEmpty
            ? (_player.queueLength > 1
                ? '${t.artist} · ${_player.queueLength} in queue'
                : t.artist)
            : '${_player.queueLength} in queue');
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openPlayer,
                child: Row(
                  children: [
                    Icon(radio ? Icons.radio : Icons.music_note,
                        size: 18, color: scheme.onSecondaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSecondaryContainer),
                          ),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSecondaryContainer
                                    .withValues(alpha: 0.8)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Skip controls only make sense for a local queue, not live radio.
            if (!radio)
              IconButton(
                tooltip: 'Previous',
                visualDensity: VisualDensity.compact,
                onPressed: () => _player.previous(),
                icon:
                    Icon(Icons.skip_previous, color: scheme.onSecondaryContainer),
              ),
            IconButton(
              tooltip: _player.isPlaying ? 'Pause' : 'Play',
              visualDensity: VisualDensity.compact,
              onPressed: () => _player.toggle(),
              icon: Icon(_player.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: scheme.onSecondaryContainer),
            ),
            if (!radio)
              IconButton(
                tooltip: 'Next',
                visualDensity: VisualDensity.compact,
                onPressed: () => _player.next(),
                icon: Icon(Icons.skip_next, color: scheme.onSecondaryContainer),
              ),
            IconButton(
              tooltip: 'Stop',
              visualDensity: VisualDensity.compact,
              onPressed: () => _player.stop(),
              icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
            ),
          ],
        ),
      ),
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

  /// Dismissible, low-key notice for things that would otherwise be invisible
  /// (e.g. some files had no extractable text). Informational, not alarming.
  Widget _noticeBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.info_outline,
            size: 18, color: scheme.onSurfaceVariant),
        title: Text(_notice!,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
        trailing: IconButton(
          icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
          visualDensity: VisualDensity.compact,
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

  // ── Photo-gallery chat queries ──────────────────────────────────────────────

  /// Detects a request for photos and returns the time range / type to show, or
  /// null if the message isn't about photos.
  ({DateTime? from, DateTime? to, PhotoType? type, String label, String content})?
      _parsePhotoQuery(String text) {
    final t = text.toLowerCase();
    const photoWords = [
      'photo', 'photos', 'picture', 'pictures', 'pic', 'pics', 'image',
      'images', 'screenshot', 'screenshots', 'meme', 'memes',
      'foto', 'fotos', 'imagem', 'imagens', 'captura', 'capturas'
    ];
    if (!photoWords.any((w) => RegExp('\\b$w\\b').hasMatch(t))) return null;
    // Content terms = meaningful words left after removing the photo/time/filler
    // words; used for caption (content) search.
    const filler = {
      'show', 'me', 'my', 'of', 'the', 'a', 'with', 'from', 'find', 'see',
      'get', 'all', 'any', 'some', 'in', 'on', 'and', 'to', 'that', 'have',
      'mostra', 'as', 'os', 'da', 'do', 'com', 'todas', 'todos',
      ...photoWords,
      'today', 'yesterday', 'week', 'month', 'year', 'last', 'this', 'past',
      'days', 'hoje', 'ontem', 'semana', 'mês', 'mes', 'ano', 'passada',
      'passado', 'este', 'esta'
    };
    final content = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(t)
        .map((m) => m.group(0)!)
        .where((w) => w.length > 1 && !filler.contains(w))
        .join(' ');

    PhotoType? type;
    if (RegExp(r'\bscreenshots?\b|\bcapturas?\b').hasMatch(t)) {
      type = PhotoType.screenshot;
    } else if (RegExp(r'\bmemes?\b').hasMatch(t)) {
      type = PhotoType.meme;
    }

    final now = DateTime.now();
    DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
    DateTime? from;
    DateTime? to;
    var label = '';
    if (RegExp(r'\btoday\b|\bhoje\b').hasMatch(t)) {
      from = startOfDay(now);
      label = ' from today';
    } else if (RegExp(r'\byesterday\b|\bontem\b').hasMatch(t)) {
      from = startOfDay(now.subtract(const Duration(days: 1)));
      to = startOfDay(now);
      label = ' from yesterday';
    } else if (RegExp(r'last week|past week|semana passada').hasMatch(t)) {
      from = startOfDay(now.subtract(Duration(days: now.weekday + 6)));
      to = startOfDay(now.subtract(Duration(days: now.weekday - 1)));
      label = ' from last week';
    } else if (RegExp(r'this week|esta semana').hasMatch(t)) {
      from = startOfDay(now.subtract(Duration(days: now.weekday - 1)));
      label = ' from this week';
    } else if (RegExp(r'last month|past month|mês passado|mes passado')
        .hasMatch(t)) {
      from = DateTime(now.year, now.month - 1, 1);
      to = DateTime(now.year, now.month, 1);
      label = ' from last month';
    } else if (RegExp(r'this month|este mês|este mes').hasMatch(t)) {
      from = DateTime(now.year, now.month, 1);
      label = ' from this month';
    } else if (RegExp(r'this year|este ano').hasMatch(t)) {
      from = DateTime(now.year, 1, 1);
      label = ' from this year';
    } else {
      final m = RegExp(r'last (\d+) days').firstMatch(t);
      if (m != null) {
        final n = int.parse(m.group(1)!);
        from = startOfDay(now.subtract(Duration(days: n)));
        label = ' from the last $n days';
      }
    }
    return (from: from, to: to, type: type, label: label, content: content);
  }

  /// Fills [assistant] with a thumbnail grid of matching photos. Returns false
  /// (so the normal model answer runs) when no photos are indexed at all.
  Future<bool> _answerWithPhotos(
      ({DateTime? from, DateTime? to, PhotoType? type, String label, String content}) q,
      ChatMessage assistant) async {
    PhotoStore? store;
    try {
      store = await _photos.openStore();
      if (store.count == 0) return false; // let the model reply normally
      // Content terms → caption (content) search; otherwise time/type listing.
      final byContent = q.content.isNotEmpty;
      final results = byContent
          ? store.searchCaptions(q.content,
              from: q.from, to: q.to, type: q.type, limit: 24)
          : store.query(from: q.from, to: q.to, type: q.type, limit: 24);
      // On-demand: if this is a content query and photos in the asked-about
      // range still lack captions, prioritise captioning that range next.
      if (byContent && store.hasUncaptionedInRange(q.from, q.to)) {
        _captionPriorityFrom = q.from;
        _captionPriorityTo = q.to;
        _maybeStartCaptioning();
      }
      final kind = q.type == PhotoType.screenshot
          ? 'screenshots'
          : q.type == PhotoType.meme
              ? 'memes'
              : 'photos';
      final about = byContent ? ' of "${q.content}"' : '';
      setState(() {
        if (results.isEmpty) {
          assistant.text = byContent
              ? 'No $kind matching "${q.content}"${q.label} yet. Photo contents '
                  'are still being recognised in the background while charging.'
              : 'No $kind found${q.label}.';
        } else {
          assistant.text = 'Here ${results.length == 1 ? 'is' : 'are'} '
              '${results.length} $kind$about${q.label}:';
          assistant.photos = results;
        }
      });
      return true;
    } catch (_) {
      return false;
    } finally {
      store?.close();
    }
  }

  Widget _photoGrid(List<PhotoInfo> photos) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 3,
          crossAxisSpacing: 3,
        ),
        itemCount: photos.length,
        itemBuilder: (context, i) {
          final p = photos[i];
          return GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PhotoViewScreen(path: p.path),
            )),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: p.thumb == null
                  ? Container(color: Colors.black12)
                  : Image.memory(p.thumb!,
                      fit: BoxFit.cover, gaplessPlayback: true),
            ),
          );
        },
      ),
    );
  }

  // ── Map / location chat queries ─────────────────────────────────────────────

  /// Detects "show me X on a map / where is X / route to X" (multilingual) and
  /// returns the place to look up plus whether a walking route was asked for, or
  /// null when the message isn't about a place.
  ({String place, bool route})? _parseMapQuery(String text) {
    final t = text.toLowerCase().trim();
    // Trigger words: the noun "map", or location/route verbs across EN/PT/ES/FR/
    // IT/DE. We only short-circuit to a map when one of these is present.
    const mapNouns = [
      'map', 'maps', 'mapa', 'mapas', 'carte', 'cartes', 'karte', 'mappa'
    ];
    final hasMapNoun = mapNouns.any((w) => RegExp('\\b$w\\b').hasMatch(t));
    // "where is X", "onde fica/está X", "dónde está X", "où est X", "wo ist X".
    final whereMatch = RegExp(
            r'\b(?:where(?:\x27s| is| are)?|onde (?:fica|está|fica o|fica a|esta)|'
            r'd[oó]nde (?:est[aá]|queda)|o[uù] (?:est|se trouve)|wo (?:ist|liegt|sind))\b')
        .firstMatch(t);
    // "route/directions/navigate to X", "rota/caminho até X", "ruta a X", etc.
    final routeMatch = RegExp(
            r'\b(?:route|directions?|navigate|way|path|rota|caminho|trajeto|'
            r'ruta|itin[ée]raire|weg|route nach)\b')
        .firstMatch(t);
    if (!hasMapNoun && whereMatch == null && routeMatch == null) return null;

    // Pull the place out of the phrase. Strip the trigger/filler words; whatever
    // significant words remain (place names, POI types) are the geocoder query.
    const filler = {
      'show', 'me', 'my', 'the', 'a', 'an', 'on', 'in', 'at', 'of', 'to',
      'is', 'are', 'where', 'wheres', 'find', 'locate', 'please', 'can', 'you',
      'get', 'go', 'how', 'do', 'i', 'from', 'here', 'near', 'nearest', 'nearby',
      'route', 'directions', 'direction', 'navigate', 'way', 'path', 'and',
      'mostra', 'onde', 'fica', 'está', 'esta', 'rota',
      'caminho', 'trajeto', 'perto', 'aqui', 'para', 'até', 'ate', 'o', 'os',
      'da', 'das', 'dos', 'um', 'uma', 'no', 'na',
      'dónde', 'donde', 'queda', 'ruta', 'cerca', 'cómo', 'como', 'llegar',
      'où', 'ou', 'est', 'se', 'trouve', 'itinéraire', 'itineraire',
      'wo', 'ist', 'liegt', 'weg', 'nach', 'dove',
      ...mapNouns,
    };
    final words = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(t)
        .map((m) => m.group(0)!)
        .where((w) => !filler.contains(w))
        .toList();
    final query = words.join(' ').trim();
    if (query.isEmpty) return null;
    return (place: query, route: routeMatch != null);
  }

  /// Geocodes the requested place via [MapService] and attaches an expandable
  /// map tile to [assistant]; for a route request it also computes a walking
  /// path from the current GPS position. Returns false (so the model answers)
  /// when maps are disabled or the place can't be resolved (offline/unknown).
  Future<bool> _answerWithMap(
      ({String place, bool route}) q, ChatMessage assistant) async {
    if (!await loadMapsEnabled()) return false;
    _setThinking('Looking up the map…');
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final geo = await MapService.instance.geocode(q.place, nowMs: nowMs);
    if (geo == null) return false; // let the model reply (offline/unknown place)
    // A short, readable name: the first part of the geocoder's display name.
    final shortName = geo.name.split(',').first.trim();

    if (q.route) {
      _setThinking('Finding a walking route…');
      final origin = await _currentPosition();
      if (origin != null) {
        final line = await MapService.instance.route(
            origin.latitude, origin.longitude, geo.lat, geo.lon,
            nowMs: nowMs);
        if (line != null && line.length >= 4) {
          setState(() {
            assistant.text = 'Here is a walking route to $shortName. Tap to open '
                'full-screen — your live position is shown as you move.';
            assistant.map = MapRef(
                lat: geo.lat,
                lon: geo.lon,
                zoom: 15,
                label: shortName,
                routeLatLngs: line);
          });
          return true;
        }
      }
      // No GPS or no route: fall back to just showing the destination.
      setState(() {
        assistant.text = origin == null
            ? 'Here is $shortName on the map. I could not get your current '
                'location to draw a route — enable location, then tap to open.'
            : 'Here is $shortName on the map. I could not find a walking route '
                'just now; tap to open with your live location.';
        assistant.map =
            MapRef(lat: geo.lat, lon: geo.lon, zoom: 14, label: shortName);
      });
      return true;
    }

    setState(() {
      assistant.text = 'Here is $shortName on the map. '
          'Tap it to open full-screen with your live location.';
      assistant.map =
          MapRef(lat: geo.lat, lon: geo.lon, zoom: 14, label: shortName);
    });
    return true;
  }

  /// The device's current position for routing, or null if location is
  /// unavailable/denied. Best-effort with a short timeout.
  Future<Position?> _currentPosition() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  /// A small, non-interactive map preview under an answer; tap to open
  /// full-screen with the live GPS dot (like the photo grid / document tiles).
  void _openMap(MapRef ref) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MapViewerScreen(title: ref.label ?? 'Map', ref: ref),
    ));
  }

  /// A citation is openable when it points at a PDF on disk, or at any other
  /// extracted-text document (opened in-app at the quote).
  bool _canOpen(Citation c) {
    if (_isPdf(c)) return true;
    if (c.wikiPath != null) return true; // offline-Wikipedia reader
    return c.docId != null; // text viewer loads the extracted text by id
  }

  bool _isPdf(Citation c) =>
      c.path != null && c.path!.toLowerCase().endsWith('.pdf');

  /// Opens a citation at the quoted passage: PDFs in the page viewer, every
  /// other document type in the in-app text viewer (scrolled to the quote).
  Future<void> _openCitation(Citation c) async {
    if (c.wikiPath != null) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WikipediaReaderScreen(
            title: c.label, articlePath: c.wikiPath!, highlight: c.snippet),
      ));
      return;
    }
    if (_isPdf(c)) {
      if (!File(c.path!).existsSync()) {
        if (mounted) {
          setState(() => _notice =
              'The original file for "${c.label}" is no longer at its saved '
              'location. Re-scan to refresh it.');
        }
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PdfViewerScreen(
            path: c.path!, title: c.label, initialPage: c.page),
      ));
      return;
    }
    // Non-PDF: render the extracted text, highlighting the cited snippet.
    final id = c.docId;
    final text = id == null ? '' : await _docs.readText(id);
    if (!mounted) return;
    if (text.trim().isEmpty) {
      setState(() => _notice =
          'The text for "${c.label}" is no longer available. Re-scan to '
          'refresh it.');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DocTextViewerScreen(
          title: c.label, fullText: text, snippet: c.snippet ?? ''),
    ));
  }

  /// Icon for a citation chip, by document type.
  IconData _citeIcon(Citation c) {
    if (c.wikiPath != null) return Icons.public;
    final p = (c.path ?? c.label).toLowerCase();
    if (p.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (p.endsWith('.epub')) return Icons.menu_book_outlined;
    if (p.endsWith('.pptx')) return Icons.slideshow_outlined;
    if (p.endsWith('.xlsx')) return Icons.table_chart_outlined;
    if (p.endsWith('.docx')) return Icons.description_outlined;
    return Icons.article_outlined;
  }

  /// One chip per cited source: collapses multiple chunks from the same document
  /// (different pages) into a single entry like "Report · pp. 2, 4" instead of
  /// several near-identical chips. Tapping opens the earliest cited page.
  List<({Citation cite, String label, IconData icon})> _groupedSources(
      List<Citation> sources) {
    final order = <String>[];
    final groups = <String, List<Citation>>{};
    for (final s in sources) {
      final key = s.wikiPath ?? s.path ?? s.docId ?? s.label;
      final list = groups[key];
      if (list == null) {
        groups[key] = [s];
        order.add(key);
      } else {
        list.add(s);
      }
    }
    return [
      for (final key in order)
        () {
          final group = groups[key]!
            ..sort((a, b) => (a.page ?? 0).compareTo(b.page ?? 0));
          return (
            cite: group.first,
            label: _citeLabel(group),
            icon: _citeIcon(group.first)
          );
        }()
    ];
  }

  String _citeLabel(List<Citation> group) {
    final first = group.first;
    // Wikipedia: the article title is enough (the globe icon says "Wikipedia").
    if (first.wikiPath != null) {
      return first.label.replaceFirst(RegExp(r'^Wikipedia:\s*'), '');
    }
    // Document name without folder/extension, ellipsized.
    var name = first.path != null
        ? first.path!.split('/').last
        : first.label.replaceAll(RegExp(r'\s*\(p\.\d+\)\s*$'), '');
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    if (name.length > 26) name = '${name.substring(0, 25)}…';
    final pages = group.map((g) => g.page).whereType<int>().toSet().toList()
      ..sort();
    if (pages.isEmpty) return name;
    return pages.length == 1
        ? '$name · p.${pages.first}'
        : '$name · pp. ${pages.join(', ')}';
  }

  /// Human-readable duration, e.g. "2 minutes and 3 seconds", "45 seconds".
  String _humanDuration(Duration d) {
    final totalSeconds = (d.inMilliseconds / 1000).round();
    if (totalSeconds < 1) return 'less than a second';
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    final parts = <String>[
      if (h > 0) '$h hour${h == 1 ? '' : 's'}',
      if (m > 0) '$m minute${m == 1 ? '' : 's'}',
      if (s > 0) '$s second${s == 1 ? '' : 's'}',
    ];
    if (parts.length <= 1) return parts.isEmpty ? 'less than a second' : parts.first;
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
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
              ? _ThinkingIndicator(
                  stage: _thinkingStage.isEmpty ? 'Thinking…' : _thinkingStage)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GptMarkdown(
                      m.text,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (m.photos != null && m.photos!.isNotEmpty)
                      _photoGrid(m.photos!),
                    if (m.map != null)
                      _MapTilePreview(ref: m.map!, onTap: () => _openMap(m.map!)),
                  ],
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
            radius: 22,
            backgroundImage: AssetImage('assets/eva_avatar.png'),
          ),
        ),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bubble,
              if (sources != null && sources.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6, top: 6, bottom: 4),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final g in _groupedSources(sources))
                        _SourceChip(
                          icon: g.icon,
                          label: g.label,
                          onTap: _canOpen(g.cite)
                              ? () => _openCitation(g.cite)
                              : null,
                        ),
                    ],
                  ),
                ),
              if (m.elapsed != null && m.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
                  child: Text(
                    'Answered in ${_humanDuration(m.elapsed!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Animated "working…" placeholder shown while the assistant prepares a reply
/// (searching documents/Wikipedia, then generating). Three pulsing dots plus a
/// short stage label, so a slow first token doesn't look frozen.
class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator({required this.stage});
  final String stage;

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final t = (_c.value - i * 0.18) % 1.0;
              final opacity = 0.3 + 0.7 * (t < 0.5 ? t * 2 : (1 - t) * 2);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Opacity(
                  opacity: opacity.clamp(0.3, 1.0),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(width: 8),
        Text(widget.stage,
            style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic)),
      ],
    );
  }
}

/// A compact, tappable source pill under an assistant reply. Quieter than a
/// Material chip: subtle surface, the source icon, the (grouped) label, and a
/// small "open" hint when it can be opened.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 13,
                  color: enabled ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 210),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ),
              if (enabled) ...[
                const SizedBox(width: 4),
                Icon(Icons.north_east,
                    size: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small, non-interactive map preview shown under an answer. Tapping opens the
/// full-screen [MapViewerScreen]. The street tile provider is loaded async (it
/// needs the cache folder), so until ready we show a neutral placeholder.
class _MapTilePreview extends StatefulWidget {
  const _MapTilePreview({required this.ref, required this.onTap});

  final MapRef ref;
  final VoidCallback onTap;

  @override
  State<_MapTilePreview> createState() => _MapTilePreviewState();
}

class _MapTilePreviewState extends State<_MapTilePreview> {
  TileProvider? _tiles;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tp = await MapService.instance.tileProvider('streets');
    if (mounted) setState(() => _tiles = tp);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dest = LatLng(widget.ref.lat, widget.ref.lon);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          onTap: widget.onTap,
          // Opaque so the tap is caught across the whole tile even though the
          // map below ignores pointers (deferToChild would otherwise miss it).
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 160,
            child: Stack(
              children: [
                Positioned.fill(
                  // IgnorePointer so FlutterMap doesn't swallow the tap — the
                  // parent GestureDetector handles it and opens the full map.
                  child: IgnorePointer(
                    child: _tiles == null
                      ? Container(color: scheme.surfaceContainerHigh)
                      : FlutterMap(
                          options: MapOptions(
                            initialCenter: dest,
                            initialZoom: widget.ref.zoom,
                            // Non-interactive: it's a preview; tap opens the map.
                            interactionOptions: const InteractionOptions(
                                flags: InteractiveFlag.none),
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: MapService.streetUrl,
                              tileProvider: _tiles!,
                              maxNativeZoom: 19,
                              userAgentPackageName: 'radio.geogram.eva',
                              errorTileCallback: (tile, error, stack) {},
                            ),
                            MarkerLayer(markers: [
                              Marker(
                                point: dest,
                                width: 36,
                                height: 36,
                                alignment: Alignment.topCenter,
                                child: const Icon(Icons.location_on,
                                    color: Colors.red, size: 36),
                              ),
                            ]),
                          ],
                        ),
                  ),
                ),
                // "Open full-screen" affordance.
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Material(
                    color: scheme.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.fullscreen,
                            size: 16, color: scheme.onSurface),
                        const SizedBox(width: 4),
                        Text('Open map',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurface)),
                      ]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
