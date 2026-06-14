import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'app_prefs.dart';
import 'assistant_channel.dart';
import 'document_service.dart';
import 'documents_screen.dart';
import 'maps/map_service.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'music_service.dart';
import 'photo_service.dart';
import 'photos_screen.dart';
import 'disk_space.dart';
import 'system_voice.dart';
import 'wikipedia_download.dart';
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
  });

  final ModelManager manager;
  final String activeId;

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
  String _corpusLocation = 'App storage (default)';
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
  String _modelsLocation = '';
  int _skippedBad = 0;
  int _photoCount = 0;
  int _musicCount = 0;
  bool _wikiEnabled = true;
  String _wikiPath = '';
  final WikipediaDownload _wikiDl = WikipediaDownload.instance;
  bool _mapsEnabled = true;
  String _mapsFolder = '';
  bool _mapsSatellite = false;
  int _mapCacheBytes = 0;
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
    _modelsLocation = await loadModelsLocation();
    _skippedBad = await _docs.skippedCount();
    _photoCount = await _photos.photoCount();
    _musicCount = await _music.trackCount();
    _wikiEnabled = await loadWikipediaEnabled();
    _wikiPath = await loadWikipediaZimPath();
    _mapsEnabled = await loadMapsEnabled();
    _mapsFolder = await loadMapsFolder();
    _mapsSatellite = await loadMapsSatellite();
    _refreshMapCacheSize();
    _documents = await _docs.list();
    _corpusLocation = await _docs.locationLabel();
    await _refreshInstalled();
    if (_voiceEngine == VoiceEngine.system) _loadLocales();
  }

  Future<void> _refreshDocs() async {
    _documents = await _docs.list();
    _corpusLocation = await _docs.locationLabel();
    if (mounted) setState(() {});
  }

  Future<void> _toast(String msg) async {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  bool _importCancelled = false;

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
    await _bulkImport(dir);
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
  Future<void> _chooseModelsLocation() async {
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
    await saveModelsLocation(dir);
    final found = await widget.manager.countModelsAt(dir);
    setState(() => _modelsLocation = dir);
    await _toast(found > 0
        ? 'Found $found model${found == 1 ? '' : 's'} there — they will be '
            'reused. New downloads go there too.'
        : 'New model downloads will be stored there.');
  }

  /// Lets the user choose a folder (e.g. SD card) for the corpus, reusing an
  /// existing archive there or offering to move the current documents into it.
  Future<void> _chooseLocation() async {
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

    // Peek at any existing pack in the target folder (without switching to it).
    final hadDocs = _documents.isNotEmpty;
    final targetManifest = await _docs.readManifestAt(dir);
    final reason = await _docs.incompatibilityReasonAt(dir);

    if (targetManifest != null) {
      // Folder already holds an archive.
      if (reason != null) {
        final useAnyway = await _confirm('Incompatible archive', reason);
        if (useAnyway != true) return;
      }
      await _docs.useLocation(dir);
      await _refreshDocs();
      await _toast('Using archive at this folder '
          '(${targetManifest['documentCount'] ?? '?'} documents).');
      return;
    }

    // Empty target folder.
    if (hadDocs) {
      final move = await _confirmThreeWay(
        'Use this folder',
        'Move your $_docsCountLabel into this folder, or start a fresh, '
            'empty archive here?',
      );
      if (move == null) return;
      if (move) {
        await _docs.moveCorpusTo(dir);
      } else {
        await _docs.useLocation(dir);
      }
    } else {
      await _docs.useLocation(dir);
    }
    await _refreshDocs();
    await _toast('Documents are now stored at this folder.');
  }

  String get _docsCountLabel =>
      '${_documents.length} document${_documents.length == 1 ? '' : 's'}';

  Future<void> _useDefaultLocation() async {
    await _docs.useDefaultLocation();
    await _refreshDocs();
    await _toast('Using app default storage.');
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
                child: const Text('Use anyway')),
          ],
        ),
      );

  // Returns true = move, false = fresh, null = cancel.
  Future<bool?> _confirmThreeWay(String title, String body) => showDialog<bool?>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, null),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Start fresh')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Move here')),
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
      await widget.manager.ensureInstalled(spec, (phase, progress) {
        if (mounted) setState(() => _downloadProgress = progress);
      });
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
        setState(() => _error = 'No Cactus models found in that folder.');
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

  @override
  Widget build(BuildContext context) {
    final busy = _downloadingId != null || _scanning || _voiceDownloading;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _sectionHeader('Appearance'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
          const Divider(),
          _sectionHeader('Persona'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
            child: Text('Longer replies take more time to generate.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                kMaxTokensChoices.contains(_maxTokens)
                    ? _maxTokens
                    : kDefaultMaxTokens
              },
              onSelectionChanged: (s) {
                setState(() => _maxTokens = s.first);
                saveMaxTokens(s.first);
              },
            ),
          ),
          const Divider(),
          _sectionHeader('Models'),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Models storage'),
            subtitle: Text(_modelsLocation.isEmpty
                ? 'App storage (cleared on uninstall)'
                : _modelsLocation),
            trailing: TextButton(
              onPressed: _chooseModelsLocation,
              child: const Text('Change'),
            ),
          ),
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
              'Cactus models, or download one below. Larger models are stronger '
              'but slower and use more memory.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          for (final m in _catalog) _modelTile(m, busy),
          const SizedBox(height: 8),
          const Divider(),
          _sectionHeader('Voice'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<VoiceEngine>(
              segments: const [
                ButtonSegment(
                  value: VoiceEngine.fast,
                  label: Text('English'),
                  icon: Icon(Icons.bolt),
                ),
                ButtonSegment(
                  value: VoiceEngine.system,
                  label: Text('System'),
                  icon: Icon(Icons.language),
                ),
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
                style: TextStyle(fontSize: 12, color: Colors.grey),
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
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
          const Divider(),
          _sectionHeader('Assistant'),
          _assistantTile(),
          const Divider(),
          _sectionHeader('Documents'),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: const Text('Browse indexed documents'),
            subtitle: Text(_documents.isEmpty
                ? 'No documents added yet.'
                : '${_documents.length} documents — view by folder, open, remove'),
            trailing: _documents.isEmpty
                ? null
                : const Icon(Icons.chevron_right),
            onTap: _documents.isEmpty
                ? null
                : () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => DocumentsScreen(docs: _docs),
                    ));
                    await _refreshDocs();
                  },
          ),
          ListTile(
            leading: const Icon(Icons.travel_explore),
            title: const Text('Scan phone for documents'),
            subtitle: const Text(
                'Finds every PDF/text file on this phone and adds it.'),
            onTap: busy ? null : () => _bulkImport('/storage/emulated/0'),
          ),
          ListTile(
            leading: const Icon(Icons.drive_folder_upload_outlined),
            title: const Text('Import documents from a folder'),
            onTap: busy ? null : _pickFolderAndImport,
          ),
          if (_skippedBad > 0)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text('Retry $_skippedBad skipped file'
                  '${_skippedBad == 1 ? '' : 's'}'),
              subtitle: const Text(
                  'Files with no extractable text are skipped on scans. Forget '
                  'that so the next scan tries them again.'),
              onTap: busy
                  ? null
                  : () async {
                      await _docs.clearSkipped();
                      setState(() => _skippedBad = 0);
                      await _toast('Skip-list cleared — they will be tried on '
                          'the next scan.');
                    },
            ),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Storage location'),
            subtitle: Text(_corpusLocation),
            isThreeLine: _corpusLocation.length > 30,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : _chooseLocation,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Choose folder…'),
                ),
                if (_corpusLocation != 'App storage (default)')
                  TextButton(
                    onPressed: busy ? null : _useDefaultLocation,
                    child: const Text('Use app default'),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'Add PDFs or text files from the chat (paperclip icon) to ask Eva '
              'about them. Search runs fully offline. Point the storage at an SD '
              'card to keep the indexed archive — it can be reused after '
              'reinstalling the app.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const Divider(),
          _sectionHeader('Photos'),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Browse photos'),
            subtitle: Text(_photoCount == 0
                ? 'Scan your gallery to browse and search photos.'
                : '$_photoCount photos indexed — view by day and type'),
            trailing:
                _photoCount == 0 ? null : const Icon(Icons.chevron_right),
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
                'Catalogs every photo with a cached thumbnail, by date and '
                'type, continuously in the background. Tap to (re)scan for new '
                'photos.'),
            onTap: () async {
              var ok = await Permission.photos.request();
              if (!ok.isGranted) ok = await Permission.storage.request();
              if (!ok.isGranted &&
                  !(await Permission.manageExternalStorage.isGranted)) {
                await _toast('Photo access is required to index the gallery.');
                return;
              }
              await savePhotoScanDone(false);
              await _toast('Photo indexing will run in the background — '
                  'progress shows at the top of the chat.');
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              'Indexing runs continuously in the background until the whole '
              'gallery is catalogued. Recognising what is inside each photo (so '
              'you can search by content) is a separate on-device pass added '
              'later.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          _sectionHeader('Music'),
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
                'Reads artist, album, title and genre tags from your audio '
                'files, then fetches lyrics online when available. Runs '
                'continuously in the background. Tap to (re)scan for new tracks.'),
            onTap: () async {
              var ok = await Permission.audio.request();
              if (!ok.isGranted) ok = await Permission.storage.request();
              if (!ok.isGranted &&
                  !(await Permission.manageExternalStorage.isGranted)) {
                await _toast('Storage access is required to index music.');
                return;
              }
              await saveMusicScanDone(false);
              await _toast('Music indexing will run in the background — '
                  'progress shows at the top of the chat.');
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              'Lyrics and genre are fetched from a free online service when the '
              'phone has internet; everything else is read on-device. This data '
              'lets Eva answer questions about your artists and songs.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          _sectionHeader('Knowledge (Offline Wikipedia)'),
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
          if (_wikiDl.downloading)
            ListTile(
              leading: const Icon(Icons.downloading),
              title: const Text('Downloading Simple English Wikipedia…'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                      value: _wikiDl.progress > 0 ? _wikiDl.progress : null),
                  const SizedBox(height: 4),
                  Text(_wikiDl.total > 0
                      ? '${formatBytes(_wikiDl.received)} of '
                          '${formatBytes(_wikiDl.total)} '
                          '(${(_wikiDl.progress * 100).round()}%)'
                      : formatBytes(_wikiDl.received)),
                ],
              ),
              trailing: TextButton(
                onPressed: _wikiDl.cancel,
                child: const Text('Cancel'),
              ),
            )
          else
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Download Simple English Wikipedia'),
              subtitle: const Text(
                  'No images, ~937 MB. Checks free space first and won\'t '
                  'download if there isn\'t room.'),
              onTap: _downloadSimpleWiki,
            ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('Install a .zim you already have'),
            subtitle: const Text(
                'Pick a Kiwix file from this device, or detect one.'),
            trailing: TextButton(
              onPressed: _scanForWiki,
              child: const Text('Detect'),
            ),
            onTap: _pickWikiFile,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              'Eva answers general-knowledge questions from the offline '
              'Wikipedia — fully offline — and cites the article, which you can '
              'open and read here. Full English is 48–115 GB if you ever want it '
              '(download from kiwix.org and install above).',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const Divider(),
          _sectionHeader('Maps (offline cache)'),
          SwitchListTile(
            secondary: const Icon(Icons.map_outlined),
            title: const Text('Show places & paths on a map'),
            subtitle: const Text(
                'Answer "where is…" / "show me … on a map" with a map tile.'),
            value: _mapsEnabled,
            onChanged: (v) async {
              await saveMapsEnabled(v);
              setState(() => _mapsEnabled = v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Map data folder'),
            subtitle: Text(_mapsFolder.isEmpty
                ? 'App storage (cleared on uninstall)'
                : _mapsFolder),
            trailing: TextButton(
              onPressed: _chooseMapsFolder,
              child: const Text('Change'),
            ),
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
            subtitle: const Text(
                'So the map can show where you are and the distance to a place.'),
            trailing: TextButton(
              onPressed: _requestLocation,
              child: const Text('Allow'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear cached map tiles'),
            subtitle: Text(_mapCacheBytes > 0
                ? '${formatBytes(_mapCacheBytes)} cached — clearing also refreshes '
                    'stale maps (re-fetched next time online).'
                : 'Nothing cached yet. Tiles you view are saved here for offline use.'),
            trailing: TextButton(
              onPressed: _mapCacheBytes > 0 ? _clearMapCache : null,
              child: const Text('Clear'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              'Maps are cached as you use them — no upfront country downloads. '
              'Areas, places and routes you have already viewed keep working '
              'offline from this folder; brand-new places need internet the first '
              'time. Point the folder at one that already has tiles to reuse them.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadSimpleWiki() async {
    await _toast('Checking free space…');
    final check = await _wikiDl.check(WikipediaDownload.simpleNopic);
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
    final ok = await _wikiDl.start(check);
    if (!mounted) return;
    if (ok) {
      _wikiPath = await loadWikipediaZimPath();
      setState(() {});
      await _toast('Simple English Wikipedia installed.');
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

  /// Chooses the folder where map tiles/geocodes cache. Pointing at a folder
  /// that already holds a cache reuses it offline (no re-fetch).
  Future<void> _chooseMapsFolder() async {
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
    await saveMapsFolder(dir);
    setState(() => _mapsFolder = dir);
    _refreshMapCacheSize();
    await _toast('Maps will cache to this folder (reused offline from here).');
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

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(text,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary)),
      );

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
