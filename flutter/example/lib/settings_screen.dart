import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'app_prefs.dart';
import 'assistant_channel.dart';
import 'document_service.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'system_voice.dart';
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _prompt.dispose();
    _voice.dispose();
    _systemVoice.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _prompt.text = await loadSystemPrompt();
    _catalog = await loadCatalog();
    _voiceInstalled = await _voice.isModelInstalled();
    _voiceEngine = await loadVoiceEngine();
    _voiceLocale = await loadVoiceLocale();
    _maxTokens = await loadMaxTokens();
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

  Future<void> _removeDocument(DocumentInfo doc) async {
    await _docs.remove(doc.id);
    _documents = await _docs.list();
    if (mounted) setState(() {});
  }

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
          ListTile(
            title: const Text('Reply length'),
            subtitle: const Text('Longer replies take more time to generate.'),
            trailing: SegmentedButton<int>(
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
          if (_documents.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('No documents added yet.',
                  style: TextStyle(color: Colors.grey)),
            )
          else
            for (final d in _documents)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(d.name),
                subtitle: Text('${(d.chars / 1000).toStringAsFixed(1)}k characters'),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _removeDocument(d),
                ),
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
        ],
      ),
    );
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
