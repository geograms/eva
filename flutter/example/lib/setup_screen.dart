import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs.dart';
import 'disk_space.dart' show formatBytes;
import 'model_catalog.dart';
import 'model_manager.dart';
import 'wikipedia_download.dart';

/// First-run setup: pick a storage folder (reusing anything already on the card)
/// and choose which models, the document-search model, and which offline
/// Wikipedia editions to download. Downloads run with per-item + overall
/// progress and resume (HTTP Range) if interrupted — the plan is persisted so a
/// killed setup picks up where it left off on the next launch.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.manager, required this.onDone});

  final ModelManager manager;
  final VoidCallback onDone;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _PlanItem {
  _PlanItem(this.kind, this.refId, this.name);
  final String kind; // 'model' | 'embedder' | 'wiki'
  final String refId; // model id / 'embedder' / wiki edition label
  final String name;
  double? progress; // 0..1, null = indeterminate
  String status = 'Queued'; // Queued | Downloading | Installed | Failed
}

class _SetupScreenState extends State<SetupScreen> {
  final _chatModels =
      kBuiltinCatalog.where((m) => !m.isEmbedder).toList(growable: false);

  String _location = '';
  bool _picking = false;
  final Set<String> _models = {kDefaultModelId};
  bool _embedder = true;
  final Set<String> _wiki = {};
  final Map<String, bool> _installed = {}; // ref id -> already present
  bool _downloading = false;
  bool _allDone = false;
  List<_PlanItem> _plan = const [];

  final WikipediaDownload _wikiDl = WikipediaDownload.instance;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _location = await loadModelsLocation();
    await _refreshInstalled();
    // Resume an interrupted setup: a saved plan means a download was started.
    final plan = await loadSetupPlan();
    if (!await loadSetupDone() &&
        plan.isNotEmpty &&
        ((plan['models'] as List?)?.isNotEmpty == true ||
            plan['embedder'] == true ||
            (plan['wiki'] as List?)?.isNotEmpty == true)) {
      _models
        ..clear()
        ..addAll(((plan['models'] as List?) ?? const []).cast<String>());
      _embedder = plan['embedder'] as bool? ?? false;
      _wiki
        ..clear()
        ..addAll(((plan['wiki'] as List?) ?? const []).cast<String>());
      if (mounted) setState(() {});
      _startDownloads(); // resume
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refreshInstalled() async {
    for (final m in _chatModels) {
      _installed[m.id] = await widget.manager.isInstalled(m);
    }
    _installed['embedder'] = await widget.manager.isInstalled(kEmbedderModel);
    for (final e in WikipediaDownload.editions) {
      _installed[e.label] = await _wikiDl.isInstalled(e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _chooseFolder() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
      }
      if (!status.isGranted) {
        _toast('Storage permission is needed to use a custom folder.');
        return;
      }
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return;
      await saveModelsLocation(dir);
      _location = dir;
      await _refreshInstalled();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _useAppStorage() async {
    await saveModelsLocation('');
    _location = '';
    await _refreshInstalled();
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  // ── Download orchestration ──────────────────────────────────────────────────

  Future<void> _startDownloads() async {
    // Build the plan (skip items already installed — they show as Installed).
    final items = <_PlanItem>[];
    for (final m in _chatModels) {
      if (_models.contains(m.id)) items.add(_PlanItem('model', m.id, m.name));
    }
    if (_embedder) {
      items.add(_PlanItem('embedder', 'embedder', kEmbedderModel.name));
    }
    for (final e in WikipediaDownload.editions) {
      if (_wiki.contains(e.label)) items.add(_PlanItem('wiki', e.label, e.label));
    }

    // Choose the active chat model: first selected non-vision, else first, else default.
    final selectedChat = _chatModels.where((m) => _models.contains(m.id)).toList();
    if (selectedChat.isNotEmpty) {
      final active = selectedChat.firstWhere((m) => !m.isVision,
          orElse: () => selectedChat.first);
      (await SharedPreferences.getInstance())
          .setString('selected_model', active.id);
    }

    // Persist the plan so an interrupted run resumes the same selection.
    await saveSetupPlan({
      'models': _models.toList(),
      'embedder': _embedder,
      'wiki': _wiki.toList(),
    });

    setState(() {
      _plan = items;
      _downloading = true;
      _allDone = false;
    });

    for (final item in _plan) {
      if (!mounted) return;
      setState(() {
        item.status = 'Downloading';
        item.progress = null;
      });
      final ok = await _downloadItem(item);
      if (!mounted) return;
      setState(() => item.status = ok ? 'Installed' : 'Failed');
    }
    if (mounted) setState(() => _allDone = true);
  }

  Future<bool> _downloadItem(_PlanItem item) async {
    try {
      if (item.kind == 'model' || item.kind == 'embedder') {
        final spec = item.kind == 'embedder'
            ? kEmbedderModel
            : _chatModels.firstWhere((m) => m.id == item.refId);
        if (await widget.manager.isInstalled(spec)) return true;
        await widget.manager.ensureInstalled(spec, (phase, p) {
          if (mounted) setState(() => item.progress = p);
        });
        return true;
      } else {
        final edition =
            WikipediaDownload.editions.firstWhere((e) => e.label == item.refId);
        if (await _wikiDl.isInstalled(edition)) return true;
        void onWiki() {
          if (mounted) {
            setState(() =>
                item.progress = _wikiDl.progress > 0 ? _wikiDl.progress : null);
          }
        }

        _wikiDl.addListener(onWiki);
        try {
          return await _wikiDl.download(edition);
        } finally {
          _wikiDl.removeListener(onWiki);
        }
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _finish() async {
    await saveSetupDone(true);
    widget.onDone();
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _downloading ? _downloadingView() : _selectionView(),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
        child: Text(t,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary)),
      );

  String _installedTag(String id) => _installed[id] == true ? ' · already downloaded' : '';

  Widget _selectionView() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Text('Set up Eva',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Text(
                  'Choose what to download now. Everything runs offline; you can '
                  'change this later in Settings. Downloads resume if interrupted.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),

              // Storage folder
              _section('Storage folder'),
              ListTile(
                leading: const Icon(Icons.sd_storage_outlined),
                title: Text(_location.isEmpty ? 'App storage (default)' : _location),
                subtitle: const Text(
                    'Point at an SD card / folder to keep downloads across '
                    'reinstalls — anything already there is reused, not re-downloaded.'),
                isThreeLine: true,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  OutlinedButton.icon(
                    onPressed: _picking ? null : _chooseFolder,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(_location.isEmpty ? 'Choose folder…' : 'Change folder…'),
                  ),
                  if (_location.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    TextButton(onPressed: _useAppStorage, child: const Text('Use app storage')),
                  ],
                ]),
              ),

              // Language models
              _section('Language model'),
              for (final m in _chatModels)
                CheckboxListTile(
                  value: _models.contains(m.id),
                  onChanged: (v) => setState(() =>
                      v == true ? _models.add(m.id) : _models.remove(m.id)),
                  title: Text(m.name),
                  subtitle: Text('${m.sizeLabel}${_installedTag(m.id)}'),
                  dense: true,
                ),

              // Document search
              _section('Document search'),
              CheckboxListTile(
                value: _embedder,
                onChanged: (v) => setState(() => _embedder = v ?? false),
                title: const Text('Document search model'),
                subtitle: Text(
                    '${kEmbedderModel.sizeLabel} · recommended to ask about your '
                    'documents${_installedTag('embedder')}'),
                dense: true,
              ),

              // Wikipedia
              _section('Offline Wikipedia (optional)'),
              for (final e in WikipediaDownload.editions)
                CheckboxListTile(
                  value: _wiki.contains(e.label),
                  onChanged: (v) => setState(() =>
                      v == true ? _wiki.add(e.label) : _wiki.remove(e.label)),
                  title: Text(e.label),
                  subtitle: Text(
                      '≈ ${formatBytes(e.approxBytes)}${_installedTag(e.label)}'),
                  dense: true,
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              TextButton(onPressed: _finish, child: const Text('Skip for now')),
              const Spacer(),
              FilledButton.icon(
                onPressed: _startDownloads,
                icon: const Icon(Icons.download),
                label: const Text('Download & continue'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _downloadingView() {
    final done = _plan.where((i) => i.status == 'Installed').length;
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 20, 4),
          child: Text('Downloading…',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text('$done of ${_plan.length} ready',
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final item in _plan)
                ListTile(
                  leading: Icon(
                    item.status == 'Installed'
                        ? Icons.check_circle
                        : item.status == 'Failed'
                            ? Icons.error_outline
                            : item.kind == 'wiki'
                                ? Icons.public
                                : Icons.memory,
                    color: item.status == 'Installed'
                        ? Colors.green
                        : item.status == 'Failed'
                            ? Colors.red
                            : null,
                  ),
                  title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: item.status == 'Downloading'
                      ? Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: LinearProgressIndicator(value: item.progress),
                        )
                      : Text(item.status),
                  trailing: item.status == 'Downloading' && item.progress != null
                      ? Text('${(item.progress! * 100).round()}%')
                      : null,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _allDone ? _finish : null,
              child: Text(_allDone ? 'Continue' : 'Downloading…'),
            ),
          ),
        ),
      ],
    );
  }
}
