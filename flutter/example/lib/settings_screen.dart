import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'app_prefs.dart';
import 'assistant_channel.dart';
import 'document_service.dart';
import 'download_service.dart';
import 'index_coordinator.dart';
import 'index_metrics.dart';
import 'indexer_screen.dart';
import 'documents_screen.dart';
import 'maps/map_service.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'music_player.dart';
import 'music_service.dart';
import 'radio_stations_screen.dart';
import 'reminder_service.dart';
import 'photo_service.dart';
import 'photos_screen.dart';
import 'disk_space.dart';
import 'system_voice.dart';
import 'updates_screen.dart';
import 'wikipedia_download.dart';
import 'wikipedia_reader_screen.dart';
import 'wikipedia_service.dart';
import 'voice_service.dart';

/// Lets the user edit the assistant persona, download/select models, and
/// sideload models from a folder. Pops with the selected model id when the user
/// switches model (null if unchanged). Persona + sideloaded models are saved to
/// preferences, so the host reloads them on return.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.activeId,
    required this.manager,
    required this.player,
    this.indexCoordinator,
  });

  final ModelManager manager;
  final String activeId;
  final MusicPlayer player;
  final IndexCoordinator? indexCoordinator;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _prompt = TextEditingController();
  final VoiceService _voice = VoiceService();
  final SystemVoiceService _systemVoice = SystemVoiceService();
  final DocumentService _docs = DocumentService();
  late final PhotoService _photos = PhotoService(_docs);
  late final MusicService _music = MusicService(_docs);
  List<DocumentInfo> _documents = const [];
  // User-chosen document folders to scan (empty = whole phone).
  List<String> _docRoots = const [];
  List<ModelSpec> _catalog = const [];
  final Set<String> _installed = {};
  String? _downloadingId;
  double? _downloadProgress;
  bool _scanning = false;
  bool _voiceInstalled = false;
  bool _voiceDownloading = false;
  double? _voiceProgress;
  VoiceEngine _voiceEngine = VoiceEngine.fast;
  String _voiceLocale = '';
  List<stt.LocaleName> _locales = const [];
  bool _localesLoading = false;
  int _maxTokens = kDefaultMaxTokens;
  int _skippedBad = 0;
  int _photoCount = 0;
  int _musicCount = 0;
  bool _wikiEnabled = true;
  String _wikiPath = '';
  final WikipediaDownload _wikiDl = WikipediaDownload.instance;
  WikiEdition? _wikiDownloadingEdition; // which edition is downloading now
  bool _mapsEnabled = true;
  bool _mapsSatellite = false;
  int _mapCacheBytes = 0;
  bool _reminderPermission = false;
  String _storageRoot = ''; // unified data folder (empty = app storage)
  bool _migrating = false;
  // Which settings area is open; null shows the top-level menu.
  String? _panel;
  String? _error;

  @override
  void initState() {
    super.initState();
    _wikiDl.addListener(_onWikiDl);
    _load();
  }

  void _onWikiDl() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _prompt.dispose();
    _voice.dispose();
    _systemVoice.dispose();
    _wikiDl.removeListener(_onWikiDl);
    super.dispose();
  }

  Future<void> _load() async {
    _prompt.text = await loadSystemPrompt();
    _catalog = await loadCatalog();
    _voiceInstalled = await _voice.isModelInstalled();
    _voiceEngine = await loadVoiceEngine();
    _voiceLocale = await loadVoiceLocale();
    _maxTokens = await loadMaxTokens();
    _skippedBad = await _docs.skippedCount();
    _photoCount = await _photos.photoCount();
    _musicCount = await _music.trackCount();
    _wikiEnabled = await loadWikipediaEnabled();
    _wikiPath = await loadWikipediaZimPath();
    _mapsEnabled = await loadMapsEnabled();
    _mapsSatellite = await loadMapsSatellite();
    _reminderPermission = await ReminderService.instance.notificationsEnabled();
    _storageRoot = await loadStorageRoot();
    _refreshMapCacheSize();
    _documents = await _docs.list();
    _docRoots = await loadDocumentRoots();
    await _refreshInstalled();
    if (_voiceEngine == VoiceEngine.system) _loadLocales();
  }

  Future<void> _refreshDocs() async {
    _documents = await _docs.list();
    if (mounted) setState(() {});
  }

  Future<void> _toast(String msg) async {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  bool _importCancelled = false;

  /// Lets the user pick a folder (e.g. their books folder, or an SD-card path)
  /// to use as the document source. The chosen folder is saved and scanned in
  /// the background — progress shows in the Indexer panel, no blocking dialog.
  Future<void> _pickFolderAndImport() async {
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }
    if (!status.isGranted) {
      await _toast('Storage permission is required to scan folders.');
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;

    // Make the picked folder the document source (replacing the whole-phone
    // default) and scan it in the background.
    final roots = {...await loadDocumentRoots(), dir}.toList();
    await saveDocumentRoots(roots);
    _docRoots = roots;
    if (mounted) setState(() {});

    final co = widget.indexCoordinator;
    if (co != null) {
      co.rescanCategory(IndexCategory.documents);
      await _toast('Scanning "$dir" in the background — see the Indexer for '
          'progress.');
    } else {
      // No coordinator available — fall back to the in-place dialog scan.
      await _bulkImport(dir);
    }
  }

  /// Walks [root] adding every supported document, with a cancellable progress
  /// dialog. Indexing itself happens later in the background (on return to the
  /// chat screen), so this only extracts text.
  Future<void> _bulkImport(String root) async {
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }
    if (!status.isGranted) {
      await _toast('Storage permission is required to scan the phone.');
      return;
    }
    _importCancelled = false;
    var scanned = 0;
    var partial = BulkImportResult();
    StateSetter? update;
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
          update = set;
          return AlertDialog(
            title: const Text('Scanning for documents'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text('Scanned $scanned files\n'
                    'Added ${partial.added} · already present '
                    '${partial.skippedExisting}\n'
                    'No text/failed ${partial.failed} · known-bad '
                    '${partial.skippedKnownBad}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => _importCancelled = true,
                child: const Text('Stop'),
              ),
            ],
          );
        }),
      );
    }
    try {
      final res = await _docs.importFolder(
        root,
        onProgress: (n, p) {
          scanned = n;
          partial = p;
          update?.call(() {});
        },
        shouldContinue: () => !_importCancelled,
      );
      await _refreshDocs();
      _skippedBad = await _docs.skippedCount();
    _photoCount = await _photos.photoCount();
    _musicCount = await _music.trackCount();
      if (mounted) setState(() {});
      await _toast('Added ${res.added} documents — ${res.failed} had no text '
          '(remembered, won\'t be re-scanned). Indexing continues in the '
          'background.');
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  /// Lets the user choose where model downloads are stored (e.g. SD card) so
  /// they survive a reinstall; an existing folder with models is reused.
  /// Chooses a single storage folder for all of Eva's data and moves the
  /// existing data into it (models, offline Wikipedia, documents, map cache), so
  /// nothing has to be downloaded again.
  Future<void> _chooseStorageFolder() async {
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }
    if (!status.isGranted) {
      await _toast('Storage permission is required to use a custom folder.');
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    if (dir == _storageRoot) return;
    final go = await _confirm(
      'Move data here?',
      'Eva will move its models and downloaded data into:\n\n$dir\n\nThis can '
          'take a while for large models. Continue?',
    );
    if (go != true) return;

    setState(() => _migrating = true);
    var step = 'Preparing…';
    StateSetter? dialogSet;
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
          dialogSet = set;
          return AlertDialog(
            title: const Text('Moving your data'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(step),
            ]),
          );
        }),
      );
    }
    try {
      await migrateStorageTo(dir, onStep: (m) {
        step = m;
        dialogSet?.call(() {});
      });
      _storageRoot = await loadStorageRoot();
      if (mounted) Navigator.of(context).pop(); // close progress dialog
      await _toast('Data moved. Everything now lives in the new folder.');
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      await _toast('Could not move all data: $e');
    } finally {
      if (mounted) setState(() => _migrating = false);
    }
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Continue')),
          ],
        ),
      );

  /// Loads the device's available recognition locales (for the system engine).
  Future<void> _loadLocales() async {
    if (_locales.isNotEmpty || _localesLoading) return;
    setState(() => _localesLoading = true);
    try {
      final ls = await _systemVoice.locales();
      ls.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) setState(() => _locales = ls);
    } catch (_) {
      // Recognizer unavailable — the dropdown will just offer "Auto".
    } finally {
      if (mounted) setState(() => _localesLoading = false);
    }
  }

  Future<void> _downloadVoice() async {
    setState(() {
      _voiceDownloading = true;
      _voiceProgress = null;
      _error = null;
    });
    try {
      await _voice.ensureModel((phase, progress) {
        if (mounted) setState(() => _voiceProgress = progress);
      });
      _voiceInstalled = true;
    } catch (e) {
      setState(() => _error = 'Voice download failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _voiceDownloading = false;
          _voiceProgress = null;
        });
      }
    }
  }

  Future<void> _refreshInstalled() async {
    _installed.clear();
    for (final m in _catalog) {
      if (await widget.manager.isInstalled(m)) _installed.add(m.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _download(ModelSpec spec) async {
    setState(() {
      _downloadingId = spec.id;
      _downloadProgress = null;
      _error = null;
    });
    try {
      // Keep the download alive if the user leaves the app / the phone sleeps.
      await DownloadService.run(
        'Downloading ${spec.name}',
        () => widget.manager.ensureInstalled(spec, (phase, progress) {
          if (mounted) setState(() => _downloadProgress = progress);
          DownloadService.update(progress == null
              ? phase
              : '${spec.name} · ${(progress * 100).round()}%');
        }),
      );
      _installed.add(spec.id);
    } catch (e) {
      setState(() => _error = 'Download failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _downloadingId = null;
          _downloadProgress = null;
        });
      }
    }
  }

  Future<void> _addFromFolder() async {
    setState(() {
      _error = null;
      _scanning = true;
    });
    try {
      // Reading an arbitrary folder needs All-files access on Android 11+.
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        setState(() => _error = 'Storage permission is required to scan a folder.');
        return;
      }

      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return; // cancelled

      final found = await widget.manager.scanFolder(dir);
      if (found.isEmpty) {
        setState(() => _error = 'No Eva models found in that folder.');
        return;
      }

      final existing = await loadSideloadedModels();
      final byId = {for (final m in existing) m.id: m};
      for (final m in found) {
        byId[m.id] = m; // dedupe by id (sideload:<path>)
      }
      await saveSideloadedModels(byId.values.toList());
      _catalog = await loadCatalog();
      await _refreshInstalled();
    } catch (e) {
      setState(() => _error = 'Could not scan folder: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _removeSideloaded(ModelSpec spec) async {
    final remaining =
        (await loadSideloadedModels()).where((m) => m.id != spec.id).toList();
    await saveSideloadedModels(remaining);
    _catalog = await loadCatalog();
    await _refreshInstalled();
  }

  // Settings are organised as a menu of areas; each opens in its own panel so
  // no single screen feels crowded.
  static const List<({String key, String title, IconData icon, String subtitle})>
      _categories = [
    // Indexer and Storage are kept at the top so the most-used controls (what
    // is being indexed, and where data lives) are visible without scrolling.
    (key: 'indexer', title: 'Indexer', icon: Icons.sync, subtitle: 'documents · music · photos — progress & control'),
    (key: 'updates', title: 'App updates', icon: Icons.system_update, subtitle: 'Check, auto-download & install new versions'),
    (key: 'storage', title: 'Storage', icon: Icons.sd_storage_outlined, subtitle: 'Where models & data are kept'),
    (key: 'appearance', title: 'Appearance', icon: Icons.palette_outlined, subtitle: 'Light / dark theme'),
    (key: 'persona', title: 'Persona & replies', icon: Icons.face_retouching_natural, subtitle: 'System prompt, reply length'),
    (key: 'models', title: 'Language model', icon: Icons.memory, subtitle: 'Choose or download the AI model'),
    (key: 'voice', title: 'Voice', icon: Icons.mic_none, subtitle: 'Speech-to-text engine & language'),
    (key: 'assistant', title: 'Phone assistant', icon: Icons.assistant_outlined, subtitle: 'Use Eva as the device assistant'),
    (key: 'documents', title: 'Documents', icon: Icons.folder_copy_outlined, subtitle: 'Index & search your files'),
    (key: 'photos', title: 'Photos', icon: Icons.photo_library_outlined, subtitle: 'Index & browse your gallery'),
    (key: 'music', title: 'Music', icon: Icons.library_music_outlined, subtitle: 'Index your audio library'),
    (key: 'radio', title: 'Radio', icon: Icons.radio, subtitle: 'Online radio stations'),
    (key: 'wikipedia', title: 'Wikipedia', icon: Icons.public, subtitle: 'Offline knowledge'),
    (key: 'maps', title: 'Maps', icon: Icons.map_outlined, subtitle: 'Offline maps & navigation'),
    (key: 'reminders', title: 'Reminders', icon: Icons.notifications_active_outlined, subtitle: 'Timed alerts'),
  ];

  @override
  Widget build(BuildContext context) {
    if (_panel == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          children: [
            for (final c in _categories)
              if (!(c.key == 'indexer' && widget.indexCoordinator == null))
                ListTile(
                  leading: Icon(c.icon),
                  title: Text(c.title),
                  subtitle: Text(c.subtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (c.key == 'radio') {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => RadioStationsScreen(player: widget.player),
                      ));
                    } else if (c.key == 'indexer') {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            IndexerScreen(coordinator: widget.indexCoordinator!),
                      ));
                    } else if (c.key == 'updates') {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const UpdatesScreen(),
                      ));
                    } else {
                      setState(() => _panel = c.key);
                    }
                  },
                ),
          ],
        ),
      );
    }

    final cat = _categories.firstWhere((c) => c.key == _panel);
    final busy = _downloadingId != null || _scanning || _voiceDownloading;
    // System back returns to the menu rather than closing Settings.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) setState(() => _panel = null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(cat.title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _panel = null),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: _panelChildren(_panel!, busy),
        ),
      ),
    );
  }

  List<Widget> _panelChildren(String key, bool busy) {
    switch (key) {
      case 'appearance':
        return _appearancePanel();
      case 'persona':
        return _personaPanel();
      case 'models':
        return _modelsPanel(busy);
      case 'voice':
        return _voicePanel(busy);
      case 'assistant':
        return [_assistantTile()];
      case 'documents':
        return _documentsPanel(busy);
      case 'photos':
        return _photosPanel();
      case 'music':
        return _musicPanel();
      case 'wikipedia':
        return _wikipediaPanel();
      case 'maps':
        return _mapsPanel();
      case 'reminders':
        return _remindersPanel();
      case 'storage':
        return _storagePanel();
    }
    return const [];
  }

  static const _hint = TextStyle(fontSize: 12, color: Colors.grey);

  List<Widget> _appearancePanel() => [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) => SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => setThemeMode(s.first),
            ),
          ),
        ),
      ];

  List<Widget> _personaPanel() => [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _prompt,
            minLines: 3,
            maxLines: 6,
            onChanged: saveSystemPrompt,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'System prompt',
              helperText: 'How the assistant should behave. Saved automatically.',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                _prompt.text = kDefaultSystemPrompt;
                saveSystemPrompt(kDefaultSystemPrompt);
              },
              child: const Text('Reset to default'),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text('Reply length'),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text('Longer replies take more time to generate.', style: _hint),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 256, label: Text('Short')),
              ButtonSegment(value: 1024, label: Text('Normal')),
              ButtonSegment(value: 2048, label: Text('Long')),
            ],
            selected: {
              kMaxTokensChoices.contains(_maxTokens) ? _maxTokens : kDefaultMaxTokens
            },
            onSelectionChanged: (s) {
              setState(() => _maxTokens = s.first);
              saveMaxTokens(s.first);
            },
          ),
        ),
      ];

  List<Widget> _modelsPanel(bool busy) => [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: OutlinedButton.icon(
            onPressed: busy ? null : _addFromFolder,
            icon: _scanning
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.folder_open),
            label: const Text('Add models from a folder…'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Point to a folder (e.g. an SD card) that already contains extracted '
            'Eva models, or download one below. Larger models are stronger but '
            'slower and use more memory. Models are kept in the Storage folder.',
            style: _hint,
          ),
        ),
        for (final m in _catalog) _modelTile(m, busy),
      ];

  List<Widget> _voicePanel(bool busy) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SegmentedButton<VoiceEngine>(
            segments: const [
              ButtonSegment(value: VoiceEngine.fast, label: Text('English'), icon: Icon(Icons.bolt)),
              ButtonSegment(value: VoiceEngine.system, label: Text('System'), icon: Icon(Icons.language)),
            ],
            selected: {_voiceEngine},
            onSelectionChanged: busy
                ? null
                : (s) async {
                    final e = s.first;
                    setState(() => _voiceEngine = e);
                    await saveVoiceEngine(e);
                    if (e == VoiceEngine.system) _loadLocales();
                  },
          ),
        ),
        if (_voiceEngine == VoiceEngine.fast) ...[
          _voiceTile(busy),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              'A fast, fully offline English model. Tap the microphone in the '
              'chat to dictate; the model is downloaded once.',
              style: _hint,
            ),
          ),
        ] else ...[
          _systemVoiceConfig(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              "Uses the phone's built-in speech recognition (many languages, "
              'including the system language). Choose a language or leave it on '
              'Auto. Works offline where the language pack is installed.',
              style: _hint,
            ),
          ),
        ],
      ];

  List<Widget> _documentsPanel(bool busy) => [
        ListTile(
          leading: const Icon(Icons.folder_copy_outlined),
          title: const Text('Browse indexed documents'),
          subtitle: Text(_documents.isEmpty
              ? 'No documents added yet.'
              : '${_documents.length} documents — view by folder, open, remove'),
          trailing: _documents.isEmpty ? null : const Icon(Icons.chevron_right),
          onTap: _documents.isEmpty
              ? null
              : () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DocumentsScreen(docs: _docs),
                  ));
                  await _refreshDocs();
                },
        ),
        // Current document source: the chosen folder(s), or the whole phone.
        ListTile(
          leading: const Icon(Icons.source_outlined),
          title: const Text('Document source'),
          subtitle: Text(_docRoots.isEmpty
              ? 'Whole phone (internal storage)'
              : _docRoots.join('\n')),
          isThreeLine: _docRoots.length > 1 ||
              _docRoots.any((r) => r.length > 30),
          trailing: _docRoots.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Reset to whole phone',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: busy
                      ? null
                      : () async {
                          await saveDocumentRoots(const []);
                          _docRoots = const [];
                          if (mounted) setState(() {});
                          await _toast('Document source reset to the whole phone.');
                        },
                ),
        ),
        ListTile(
          leading: const Icon(Icons.drive_folder_upload_outlined),
          title: const Text('Choose a folder to scan'),
          subtitle: const Text(
              'Pick your books/documents folder (or an SD-card path). It becomes '
              'the source and is scanned in the background — progress shows in '
              'the Indexer.'),
          onTap: busy ? null : _pickFolderAndImport,
        ),
        ListTile(
          leading: const Icon(Icons.travel_explore),
          title: const Text('Scan whole phone instead'),
          subtitle: Text(widget.indexCoordinator == null
              ? 'Finds every PDF/text file on this phone and adds it.'
              : 'Clears the chosen folder and scans all internal storage in the '
                  'background. Track it in the Indexer.'),
          onTap: busy
              ? null
              : () async {
                  var status = await Permission.manageExternalStorage.status;
                  if (!status.isGranted) {
                    status = await Permission.manageExternalStorage.request();
                  }
                  if (!status.isGranted) {
                    await _toast('Storage permission is required to scan the phone.');
                    return;
                  }
                  // Reset to whole-phone scanning.
                  await saveDocumentRoots(const []);
                  _docRoots = const [];
                  if (mounted) setState(() {});
                  final co = widget.indexCoordinator;
                  if (co == null) {
                    await _bulkImport('/storage/emulated/0');
                    return;
                  }
                  co.rescanCategory(IndexCategory.documents);
                  await _toast('Scanning the whole phone in the background — open '
                      'the Indexer to watch progress.');
                },
        ),
        if (_skippedBad > 0)
          ListTile(
            leading: const Icon(Icons.refresh),
            title: Text('Retry $_skippedBad skipped file${_skippedBad == 1 ? '' : 's'}'),
            subtitle: const Text(
                'Files with no extractable text are skipped on scans. Forget '
                'that so the next scan tries them again.'),
            onTap: busy
                ? null
                : () async {
                    await _docs.clearSkipped();
                    setState(() => _skippedBad = 0);
                    await _toast('Skip-list cleared — they will be tried on the next scan.');
                  },
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text(
            'Add PDFs or text files from the chat (paperclip icon) to ask Eva '
            'about them. Search runs fully offline. Files are kept in the Storage '
            'folder, so they can be reused after reinstalling the app.',
            style: _hint,
          ),
        ),
      ];

  List<Widget> _photosPanel() => [
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Browse photos'),
          subtitle: Text(_photoCount == 0
              ? 'Scan your gallery to browse and search photos.'
              : '$_photoCount photos indexed — view by day and type'),
          trailing: _photoCount == 0 ? null : const Icon(Icons.chevron_right),
          onTap: _photoCount == 0
              ? null
              : () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PhotosScreen(photos: _photos),
                  ));
                },
        ),
        ListTile(
          leading: const Icon(Icons.image_search),
          title: const Text('Index photo gallery'),
          subtitle: const Text(
              'Catalogs every photo with a cached thumbnail, by date and type, '
              'continuously in the background. Tap to (re)scan for new photos.'),
          onTap: () async {
            var ok = await Permission.photos.request();
            if (!ok.isGranted) ok = await Permission.storage.request();
            if (!ok.isGranted && !(await Permission.manageExternalStorage.isGranted)) {
              await _toast('Photo access is required to index the gallery.');
              return;
            }
            await savePhotoScanDone(false);
            await _toast('Photo indexing will run in the background — progress shows at the top of the chat.');
          },
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            'Indexing runs continuously in the background until the whole gallery '
            'is catalogued. Recognising what is inside each photo (so you can '
            'search by content) is a separate on-device pass added later.',
            style: _hint,
          ),
        ),
      ];

  List<Widget> _musicPanel() => [
        ListTile(
          leading: const Icon(Icons.library_music_outlined),
          title: const Text('Music library'),
          subtitle: Text(_musicCount == 0
              ? 'Scan your audio files to catalog artists, albums and songs.'
              : '$_musicCount tracks indexed — ask Eva about your artists'),
        ),
        ListTile(
          leading: const Icon(Icons.audiotrack),
          title: const Text('Index music library'),
          subtitle: const Text(
              'Reads artist, album, title and genre tags from your audio files, '
              'then fetches lyrics online when available. Runs continuously in '
              'the background. Tap to (re)scan for new tracks.'),
          onTap: () async {
            var ok = await Permission.audio.request();
            if (!ok.isGranted) ok = await Permission.storage.request();
            if (!ok.isGranted && !(await Permission.manageExternalStorage.isGranted)) {
              await _toast('Storage access is required to index music.');
              return;
            }
            await saveMusicScanDone(false);
            await _toast('Music indexing will run in the background — progress shows at the top of the chat.');
          },
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'Lyrics and genre are fetched from a free online service when the '
            'phone has internet; everything else is read on-device.',
            style: _hint,
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.radio),
          title: const Text('Radio stations'),
          subtitle: const Text('Online stations to play. Comes with examples.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RadioStationsScreen(player: widget.player),
          )),
        ),
      ];

  List<Widget> _remindersPanel() => [
        SwitchListTile(
          secondary: const Icon(Icons.notifications_active_outlined),
          title: const Text('Allow timed reminders'),
          subtitle: Text(_reminderPermission
              ? 'Eva can post reminder notifications.'
              : 'Tap to allow notifications so reminders can alert you.'),
          value: _reminderPermission,
          onChanged: (_) async {
            final ok = await ReminderService.instance.requestPermissions();
            setState(() => _reminderPermission = ok);
            await _toast(ok
                ? 'Reminders enabled.'
                : 'Notifications are blocked — enable them in system settings.');
          },
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(
            'Ask in chat, e.g. "remind me to call mum in 15 minutes" or "set a '
            'reminder for 7pm to leave". Reminders fire as system notifications '
            'even if Eva is closed.',
            style: _hint,
          ),
        ),
      ];

  List<Widget> _wikipediaPanel() => [
        SwitchListTile(
          secondary: const Icon(Icons.public),
          title: const Text('Use Wikipedia to help answer'),
          subtitle: Text(_wikiPath.isEmpty
              ? 'No Wikipedia installed yet.'
              : 'Installed: ${_wikiPath.split('/').last}'),
          value: _wikiEnabled,
          onChanged: (v) async {
            await saveWikipediaEnabled(v);
            setState(() => _wikiEnabled = v);
          },
        ),
        if (_wikiPath.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.auto_stories),
            title: const Text('Browse & read articles'),
            subtitle: const Text('Open the installed edition — search or read a random article.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _browseWiki,
          ),
        if (_wikiDl.downloading)
          ListTile(
            leading: const Icon(Icons.downloading),
            title: Text('Downloading ${_wikiDownloadingEdition?.label ?? 'Wikipedia'}…'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                LinearProgressIndicator(value: _wikiDl.progress > 0 ? _wikiDl.progress : null),
                const SizedBox(height: 4),
                Text(_wikiDl.total > 0
                    ? '${formatBytes(_wikiDl.received)} of ${formatBytes(_wikiDl.total)} '
                        '(${(_wikiDl.progress * 100).round()}%)'
                    : formatBytes(_wikiDl.received)),
              ],
            ),
            trailing: TextButton(onPressed: _wikiDl.cancel, child: const Text('Cancel')),
          )
        else ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Download an edition', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final e in WikipediaDownload.editions)
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(e.label),
              subtitle: Text('≈ ${formatBytes(e.approxBytes)} · checks free space first'),
              onTap: () => _downloadWiki(e),
            ),
        ],
        const Divider(),
        ListTile(
          leading: const Icon(Icons.file_open_outlined),
          title: const Text('Install a .zim you already have'),
          subtitle: const Text('Pick a Kiwix file from this device, or detect one.'),
          trailing: TextButton(onPressed: _scanForWiki, child: const Text('Detect')),
          onTap: _pickWikiFile,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            'Eva answers general-knowledge questions from the offline Wikipedia — '
            'fully offline — and cites the article, which you can open and read '
            'here. Sizes are estimates; the download is skipped if it won\'t fit. '
            'Any other .zim from kiwix.org can be sideloaded above.',
            style: _hint,
          ),
        ),
      ];

  List<Widget> _mapsPanel() => [
        SwitchListTile(
          secondary: const Icon(Icons.map_outlined),
          title: const Text('Show places & paths on a map'),
          subtitle: const Text('Answer "where is…" / "show me … on a map" with a map tile.'),
          value: _mapsEnabled,
          onChanged: (v) async {
            await saveMapsEnabled(v);
            setState(() => _mapsEnabled = v);
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.satellite_alt),
          title: const Text('Open maps in satellite view'),
          subtitle: const Text('Otherwise streets, roads and paths.'),
          value: _mapsSatellite,
          onChanged: (v) async {
            await saveMapsSatellite(v);
            setState(() => _mapsSatellite = v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.my_location),
          title: const Text('Allow location for the live dot'),
          subtitle: const Text('So the map can show where you are and the distance to a place.'),
          trailing: TextButton(onPressed: _requestLocation, child: const Text('Allow')),
        ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('Clear cached map tiles'),
          subtitle: Text(_mapCacheBytes > 0
              ? '${formatBytes(_mapCacheBytes)} cached — clearing also refreshes stale maps (re-fetched next time online).'
              : 'Nothing cached yet. Tiles you view are saved for offline use.'),
          trailing: TextButton(
            onPressed: _mapCacheBytes > 0 ? _clearMapCache : null,
            child: const Text('Clear'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            'Maps are cached as you use them — no upfront country downloads. Areas, '
            'places and routes you have already viewed keep working offline; '
            'brand-new places need internet the first time. The cache lives in the '
            'Storage folder.',
            style: _hint,
          ),
        ),
      ];

  List<Widget> _storagePanel() => [
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title: const Text('Storage folder'),
          subtitle: Text(_storageRoot.isEmpty
              ? 'App storage (cleared on uninstall)'
              : _storageRoot),
          isThreeLine: _storageRoot.length > 30,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: OutlinedButton.icon(
            onPressed: _migrating ? null : _chooseStorageFolder,
            icon: _migrating
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.drive_file_move_outline),
            label: Text(_migrating ? 'Moving files…' : 'Choose folder & move data…'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            'One folder holds everything Eva downloads: AI models, the offline '
            'Wikipedia, your documents and the map cache. Choosing a new folder '
            '(e.g. an SD card) moves all existing data there so nothing has to be '
            'downloaded again. Pointing at a folder that already holds Eva data '
            'reuses it.',
            style: _hint,
          ),
        ),
      ];

  Future<void> _downloadWiki(WikiEdition edition) async {
    await _toast('Checking free space…');
    final check = await _wikiDl.check(edition);
    if (check == null) {
      await _toast('Could not reach the download server. Check your internet.');
      return;
    }
    if (!check.ok) {
      final need = formatBytes(check.needBytes);
      final free = check.freeBytes == null ? 'unknown' : formatBytes(check.freeBytes!);
      await _toast('Not enough storage: needs about $need free, but only '
          '$free is available. Free up space and try again.');
      return;
    }
    setState(() => _wikiDownloadingEdition = edition);
    void onProgress() => DownloadService.update(
        '${edition.label} · ${(_wikiDl.progress * 100).round()}%');
    _wikiDl.addListener(onProgress);
    final ok = await DownloadService.run(
      'Downloading ${edition.label}',
      () => _wikiDl.start(check),
    );
    _wikiDl.removeListener(onProgress);
    if (!mounted) return;
    setState(() => _wikiDownloadingEdition = null);
    if (ok) {
      _wikiPath = await loadWikipediaZimPath();
      setState(() {});
      await _toast('${edition.label} installed.');
    } else if (_wikiDl.error != null) {
      await _toast(_wikiDl.error!);
    } else {
      await _toast('Download cancelled.');
    }
  }

  Future<void> _pickWikiFile() async {
    final ok = await Permission.storage.request();
    if (!ok.isGranted && !(await Permission.manageExternalStorage.isGranted)) {
      // proceed anyway — the picker may still work via the system UI
    }
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = res?.files.single.path;
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.zim')) {
      await _toast('That is not a .zim file.');
      return;
    }
    await saveWikipediaZimPath(path);
    if (mounted) setState(() => _wikiPath = path);
    await _toast('Wikipedia installed — Eva can now use it.');
  }

  /// Opens the installed Wikipedia at its main page for free browsing/reading.
  Future<void> _browseWiki() async {
    final wiki = WikipediaService.instance;
    if (!await wiki.ensureOpen()) {
      await _toast('Could not open the installed Wikipedia.');
      return;
    }
    final path = await wiki.mainPath();
    if (!mounted || path.isEmpty) {
      await _toast('This edition has no main page to open.');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WikipediaReaderScreen(title: 'Wikipedia', articlePath: path),
    ));
  }

  Future<void> _scanForWiki() async {
    await Permission.storage.request();
    await _toast('Searching this device for a Wikipedia file…');
    final found = await WikipediaService.instance.scanForZim();
    if (found == null) {
      await _toast('No .zim file found. Download one and put it in Downloads.');
      return;
    }
    await saveWikipediaZimPath(found);
    if (mounted) setState(() => _wikiPath = found);
    await _toast('Found ${found.split('/').last}.');
  }

  Future<void> _requestLocation() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      await _toast('Location is blocked. Enable it in system settings for the '
          'live dot.');
    } else if (perm == LocationPermission.denied) {
      await _toast('Location permission not granted.');
    } else {
      await _toast('Location enabled — the map can show your live position.');
    }
  }

  /// Sums the cached tile/geo files on disk (best-effort, async).
  Future<void> _refreshMapCacheSize() async {
    try {
      final root = await MapService.instance.cacheRoot();
      final dir = Directory(root);
      var total = 0;
      if (await dir.exists()) {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              total += await e.length();
            } catch (_) {}
          }
        }
      }
      if (mounted) setState(() => _mapCacheBytes = total);
    } catch (_) {}
  }

  Future<void> _clearMapCache() async {
    final ok = await _confirm('Clear cached maps',
        'Delete all cached map tiles and looked-up places? They will be '
        're-fetched next time you view them online.');
    if (ok != true) return;
    try {
      final root = await MapService.instance.cacheRoot();
      final dir = Directory(root);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    await _refreshMapCacheSize();
    await _toast('Cached maps cleared.');
  }

  Widget _systemVoiceConfig() {
    // The dropdown value must be one of the item values; fall back to Auto ('')
    // until the device locales have loaded.
    final values = {'', for (final l in _locales) l.localeId};
    final value = values.contains(_voiceLocale) ? _voiceLocale : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: value,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Language',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(
                    value: '', child: Text('Auto (system language)')),
                for (final l in _locales)
                  DropdownMenuItem(value: l.localeId, child: Text(l.name)),
              ],
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _voiceLocale = v);
                await saveVoiceLocale(v);
              },
            ),
          ),
          if (_localesLoading)
            const Padding(
              padding: EdgeInsets.only(left: 12),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
    );
  }

  Widget _voiceTile(bool busy) {
    Widget trailing;
    if (_voiceDownloading) {
      trailing = SizedBox(
        width: 120,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: _voiceProgress),
            const SizedBox(height: 4),
            Text(
              _voiceProgress == null
                  ? 'Working…'
                  : '${(_voiceProgress! * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      );
    } else if (_voiceInstalled) {
      trailing = const Chip(
        avatar: Icon(Icons.check, size: 18),
        label: Text('Installed'),
      );
    } else {
      trailing = OutlinedButton.icon(
        onPressed: busy ? null : _downloadVoice,
        icon: const Icon(Icons.download, size: 18),
        label: const Text('Download'),
      );
    }
    return ListTile(
      leading: const Icon(Icons.mic_none),
      title: const Text('English speech-to-text'),
      subtitle: const Text('~57 MB download · offline dictation'),
      trailing: trailing,
    );
  }

  Future<bool>? _assistantStatus;

  Widget _assistantTile() {
    _assistantStatus ??= AssistantChannel.isAssistant();
    return FutureBuilder<bool>(
      future: _assistantStatus,
      builder: (context, snap) {
        final isAssistant = snap.data ?? false;
        return ListTile(
          leading: const Icon(Icons.assistant_outlined),
          title: const Text('Use Eva as your phone assistant'),
          subtitle: Text(isAssistant
              ? 'Eva is your default assistant — press and hold the power '
                  'button to talk to it.'
              : 'Make Eva the default digital assistant, then press and hold '
                  'the power button to talk to it.'),
          trailing: isAssistant
              ? const Icon(Icons.check_circle, color: Colors.green)
              : const Text('Set up'),
          onTap: () async {
            await AssistantChannel.requestAssistantRole();
            if (mounted) {
              setState(() => _assistantStatus = AssistantChannel.isAssistant());
            }
          },
        );
      },
    );
  }

  Widget _modelTile(ModelSpec m, bool busy) {
    final isActive = m.id == widget.activeId;
    final isInstalled = _installed.contains(m.id);
    final isDownloading = _downloadingId == m.id;

    Widget trailing;
    if (isActive) {
      trailing = const Chip(
        avatar: Icon(Icons.check, size: 18),
        label: Text('Active'),
      );
    } else if (isDownloading) {
      trailing = SizedBox(
        width: 120,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: _downloadProgress),
            const SizedBox(height: 4),
            Text(
              _downloadProgress == null
                  ? 'Working…'
                  : '${(_downloadProgress! * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      );
    } else if (isInstalled) {
      trailing = FilledButton(
        onPressed: busy ? null : () => Navigator.of(context).pop(m.id),
        child: const Text('Use'),
      );
    } else {
      trailing = OutlinedButton.icon(
        onPressed: busy ? null : () => _download(m),
        icon: const Icon(Icons.download, size: 18),
        label: const Text('Download'),
      );
    }

    return ListTile(
      title: Text(m.name),
      subtitle: Text(m.sizeLabel),
      trailing: trailing,
      leading: m.isSideloaded && !isActive
          ? IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline),
              onPressed: busy ? null : () => _removeSideloaded(m),
            )
          : null,
    );
  }
}
