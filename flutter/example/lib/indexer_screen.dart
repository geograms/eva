import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_prefs.dart';
import 'index_coordinator.dart';
import 'index_metrics.dart';

/// One panel to see and coordinate all background indexing — documents, music,
/// photos, and photo captions. Shows per-category progress, time spent and an
/// estimate of time remaining, surfaces when a permission is still needed, and
/// offers pause/resume per category plus "pause all" / "index now". All work
/// runs under a foreground service (held by [IndexCoordinator]) so it continues
/// when the app is backgrounded or the phone is suspended.
class IndexerScreen extends StatefulWidget {
  const IndexerScreen({super.key, required this.coordinator});

  final IndexCoordinator coordinator;

  @override
  State<IndexerScreen> createState() => _IndexerScreenState();
}

class _IndexerScreenState extends State<IndexerScreen> with WidgetsBindingObserver {
  bool _photosGranted = false;
  bool _musicGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.coordinator.addListener(_onChange);
    widget.coordinator.kick();
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.coordinator.removeListener(_onChange);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshPermissions() async {
    final photos = await Permission.photos.isGranted ||
        await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted;
    final music = await Permission.audio.isGranted ||
        await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted;
    if (!mounted) return;
    setState(() {
      _photosGranted = photos;
      _musicGranted = music;
    });
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _grantAndScan(IndexCategory cat) async {
    final isMusic = cat == IndexCategory.music;
    var ok = await (isMusic ? Permission.audio : Permission.photos).request();
    if (!ok.isGranted) ok = await Permission.storage.request();
    if (!ok.isGranted && !(await Permission.manageExternalStorage.isGranted)) {
      _toast('Storage access is required to index '
          '${isMusic ? 'music' : 'photos'}.');
      return;
    }
    await (isMusic ? saveMusicScanDone(false) : savePhotoScanDone(false));
    widget.coordinator.rescanCategory(cat);
    await _refreshPermissions();
    _toast('Indexing started — it continues in the background.');
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final co = widget.coordinator;
    return Scaffold(
      appBar: AppBar(title: const Text('Indexer')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _header(),
          _card(co.snapshot(IndexCategory.documents),
              icon: Icons.description_outlined),
          _card(co.snapshot(IndexCategory.music),
              icon: Icons.library_music_outlined,
              needsPermission: !_musicGranted),
          _card(co.snapshot(IndexCategory.photos),
              icon: Icons.photo_library_outlined,
              needsPermission: !_photosGranted),
          _card(co.snapshot(IndexCategory.captions),
              icon: Icons.auto_awesome_outlined,
              chargingOnly: true),
        ],
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  Widget _header() {
    final total = widget.coordinator.totalElapsed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Total time indexed: ${_fmtDuration(total)}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            'Documents are first discovered (the whole phone is walked for '
            'PDFs/text), then indexed with the AI engine, which pauses while you '
            'chat; music and photos are light file scans. Everything runs in the '
            'background and keeps going if you leave the app or the phone sleeps. '
            'Use "Rescan for files" to pick up newly-added files. Photo captions '
            'need the vision model, so they run while charging.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _card(
    IndexSnapshot s, {
    required IconData icon,
    bool needsPermission = false,
    bool chargingOnly = false,
  }) {
    final theme = Theme.of(context);
    final color = switch (s.status) {
      IndexStatus.done => Colors.green,
      IndexStatus.paused => Colors.orange,
      _ => theme.colorScheme.primary,
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.category.label,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                _trailing(s, needsPermission: needsPermission),
              ],
            ),
            const SizedBox(height: 8),
            _progressBar(s),
            const SizedBox(height: 6),
            Text(_primaryLine(s, needsPermission: needsPermission, chargingOnly: chargingOnly),
                style: TextStyle(fontSize: 13, color: color)),
            if (s.elapsedTotal.inSeconds > 0 || s.eta != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(_metricsLine(s),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ..._cardActions(s, needsPermission: needsPermission, chargingOnly: chargingOnly),
          ],
        ),
      ),
    );
  }

  List<Widget> _cardActions(IndexSnapshot s,
      {required bool needsPermission, required bool chargingOnly}) {
    if (needsPermission) {
      return _wrapActions([
        FilledButton.tonalIcon(
          onPressed: () => _grantAndScan(s.category),
          icon: const Icon(Icons.lock_open, size: 18),
          label: const Text('Grant access & scan'),
        ),
      ]);
    }

    final buttons = <Widget>[];

    if (chargingOnly && s.pending > 0 && !s.isBusy) {
      // Captions waiting on the charging gate: let the user force a pass.
      buttons.add(OutlinedButton.icon(
        onPressed: _onIndexNow,
        icon: const Icon(Icons.bolt, size: 18),
        label: const Text('Index now'),
      ));
    }

    // Documents, music and photos can always be re-walked to discover new files
    // and add them to the processing queue. The scan runs in the background, so
    // it keeps going if the user leaves the app or the phone sleeps.
    if (s.category == IndexCategory.documents ||
        s.category == IndexCategory.music ||
        s.category == IndexCategory.photos) {
      // Never scanned yet → "Scan now"; otherwise "Rescan for files".
      final firstScan = s.status == IndexStatus.idle && s.done == 0;
      buttons.add(OutlinedButton.icon(
        onPressed: s.status == IndexStatus.scanning
            ? null
            : () {
                widget.coordinator.rescanCategory(s.category);
                _toast('Scanning for files in the background — they will be '
                    'added to the queue.');
              },
        icon: Icon(firstScan ? Icons.search : Icons.refresh, size: 18),
        label: Text(firstScan ? 'Scan now' : 'Rescan for files'),
      ));
    }

    return _wrapActions(buttons);
  }

  List<Widget> _wrapActions(List<Widget> buttons) {
    if (buttons.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 8, runSpacing: 8, children: buttons),
      ),
    ];
  }

  Widget _progressBar(IndexSnapshot s) {
    if (s.status == IndexStatus.scanning && s.total == null) {
      return const LinearProgressIndicator(); // indeterminate: total unknown
    }
    double? value;
    if (s.total != null && s.total! > 0) {
      value = (s.done / s.total!).clamp(0.0, 1.0);
    } else if (s.status == IndexStatus.done) {
      value = 1.0;
    } else {
      value = 0.0;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(value: value, minHeight: 6),
    );
  }

  Widget _trailing(IndexSnapshot s, {required bool needsPermission}) {
    if (needsPermission) return const SizedBox.shrink();
    final busy = s.isBusy;
    final paused = s.status == IndexStatus.paused;
    if (!busy && !paused && s.pending == 0 && s.status == IndexStatus.done) {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    return IconButton(
      tooltip: paused ? 'Resume' : 'Pause',
      icon: Icon(paused ? Icons.play_arrow : Icons.pause),
      onPressed: () => paused
          ? widget.coordinator.resume(s.category)
          : widget.coordinator.pause(s.category),
    );
  }

  String _primaryLine(IndexSnapshot s,
      {required bool needsPermission, required bool chargingOnly}) {
    if (needsPermission) return 'Tap "Grant access & scan" to start.';
    switch (s.status) {
      case IndexStatus.paused:
        return 'Paused';
      case IndexStatus.done:
        return 'Up to date';
      case IndexStatus.scanning:
        final rate = s.itemsPerSec >= 1 ? ' · ${s.itemsPerSec.round()}/s' : '';
        // For documents, currentName carries the running "added N" count.
        final extra = s.currentName != null ? ' · ${s.currentName}' : '';
        return 'Scanning · ${s.done} files$rate$extra';
      case IndexStatus.indexing:
        final of = (s.total != null && s.total! > 0) ? '${s.done} of ${s.total}' : '${s.done}';
        final name = s.currentName != null ? ' · ${s.currentName}' : '';
        return 'Indexing $of$name';
      case IndexStatus.idle:
        if (s.pending > 0) {
          return chargingOnly
              ? '${s.pending} pending · runs while charging'
              : '${s.pending} pending';
        }
        return chargingOnly ? 'Runs while charging' : 'Waiting';
    }
  }

  String _metricsLine(IndexSnapshot s) {
    final parts = <String>[];
    if (s.elapsedTotal.inSeconds > 0) {
      parts.add('time spent ${_fmtDuration(s.elapsedTotal)}');
    }
    if (s.eta != null) {
      parts.add('~${_fmtDuration(s.eta!)} left');
    } else if (s.pending > 0 &&
        (s.category == IndexCategory.documents ||
            s.category == IndexCategory.captions)) {
      parts.add('estimating…');
    }
    return parts.join(' · ');
  }

  Widget _bottomBar() {
    final co = widget.coordinator;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: co.anyActive ? co.pauseAll : null,
                icon: const Icon(Icons.pause),
                label: const Text('Pause all'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _onIndexNow,
                icon: const Icon(Icons.bolt),
                label: const Text('Index now'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onIndexNow() async {
    if (!widget.coordinator.charging) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Index now?'),
          content: const Text(
              'Photo captioning normally waits until the phone is charging '
              'because it uses the AI vision model. Run it now anyway? This '
              'will use more battery.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Index now')),
          ],
        ),
      );
      if (go != true) return;
    }
    await widget.coordinator.indexNow();
  }

  static String _fmtDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) {
      final s = d.inSeconds % 60;
      return s == 0 ? '${d.inMinutes}m' : '${d.inMinutes}m ${s}s';
    }
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
  }
}
