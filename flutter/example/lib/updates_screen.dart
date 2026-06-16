import 'package:flutter/material.dart';

import 'app_prefs.dart';
import 'app_updater.dart';

/// Full-screen panel to view the installed/available version and drive the
/// in-app updater: download + install a newer APK, grant the one-time "Install
/// unknown apps" permission, toggle automatic updates, and point the updater at
/// a different release-API URL.
class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen>
    with WidgetsBindingObserver {
  final AppUpdater _updater = AppUpdater.instance;
  final TextEditingController _url = TextEditingController();
  bool _autoUpdate = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updater.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updater.removeListener(_onChange);
    _url.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have just toggled "Install unknown apps" in system settings.
    if (state == AppLifecycleState.resumed) _updater.refreshPermission();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    _autoUpdate = await loadAutoUpdate();
    _url.text = await loadUpdateUrl();
    if (mounted) setState(() {});
    // Check on open unless a flow is already running.
    if (!_updater.busy &&
        _updater.status != UpdateStatus.available &&
        _updater.status != UpdateStatus.readyToInstall) {
      _updater.check();
    } else {
      _updater.refreshPermission();
    }
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App updates')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _versionCard(),
          if (!_updater.isDevBuild && !_updater.canInstall) _permissionTile(),
          _autoUpdateTile(),
          const Divider(),
          _urlSection(),
        ],
      ),
    );
  }

  Widget _versionCard() {
    final u = _updater;
    final installed = u.isDevBuild ? 'Development build' : u.currentTag;
    final available = u.latest?.tag;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Installed: $installed',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_statusLine(),
                style: TextStyle(
                    fontSize: 13,
                    color: u.status == UpdateStatus.error
                        ? Theme.of(context).colorScheme.error
                        : Colors.grey[700])),
            if (available != null && u.updateAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Available: $available',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            if (u.status == UpdateStatus.downloading ||
                u.status == UpdateStatus.verifying) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                    value: u.status == UpdateStatus.verifying
                        ? null
                        : u.progress,
                    minHeight: 6),
              ),
            ],
            const SizedBox(height: 12),
            _actions(),
          ],
        ),
      ),
    );
  }

  String _statusLine() {
    final u = _updater;
    switch (u.status) {
      case UpdateStatus.idle:
        return u.isDevBuild
            ? 'Development build — automatic updates are disabled.'
            : 'Tap "Check for updates".';
      case UpdateStatus.checking:
        return 'Checking for updates…';
      case UpdateStatus.upToDate:
        return 'Eva is up to date.';
      case UpdateStatus.available:
        return u.canInstall
            ? 'A newer version is available.'
            : 'A newer version is available — allow installs to continue.';
      case UpdateStatus.downloading:
        return u.progress == null
            ? 'Downloading…'
            : 'Downloading… ${(u.progress! * 100).round()}%';
      case UpdateStatus.verifying:
        return 'Verifying download…';
      case UpdateStatus.readyToInstall:
        return 'Opening the installer…';
      case UpdateStatus.installing:
        return 'Follow the system prompt to finish installing.';
      case UpdateStatus.error:
        return u.error ?? 'Something went wrong.';
    }
  }

  Widget _actions() {
    final u = _updater;
    if (u.isDevBuild) {
      return const Text(
        'Updates apply to release builds installed from a published APK.',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    final buttons = <Widget>[];
    switch (u.status) {
      case UpdateStatus.checking:
        buttons.add(const FilledButton(
          onPressed: null,
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ));
      case UpdateStatus.downloading:
        buttons.add(OutlinedButton.icon(
          onPressed: u.cancel,
          icon: const Icon(Icons.close, size: 18),
          label: const Text('Cancel'),
        ));
      case UpdateStatus.verifying:
      case UpdateStatus.readyToInstall:
      case UpdateStatus.installing:
        buttons.add(const FilledButton(onPressed: null, child: Text('Working…')));
        if (u.status == UpdateStatus.installing) {
          buttons.add(FilledButton.icon(
            onPressed: u.downloadAndInstall,
            icon: const Icon(Icons.system_update_alt, size: 18),
            label: const Text('Reopen installer'),
          ));
        }
      case UpdateStatus.available:
        buttons.add(FilledButton.icon(
          onPressed: u.downloadAndInstall,
          icon: const Icon(Icons.download, size: 18),
          label: Text(u.canInstall ? 'Download & install' : 'Allow & update'),
        ));
      case UpdateStatus.idle:
      case UpdateStatus.upToDate:
      case UpdateStatus.error:
        buttons.add(FilledButton.icon(
          onPressed: u.check,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Check for updates'),
        ));
        if (u.updateAvailable) {
          buttons.add(FilledButton.icon(
            onPressed: u.downloadAndInstall,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download & install'),
          ));
        }
    }
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _permissionTile() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        leading: const Icon(Icons.shield_outlined),
        title: const Text('Allow Eva to install apps'),
        subtitle: const Text(
            'Android requires a one-time permission ("Install unknown apps") '
            'before Eva can install an update.'),
        trailing: TextButton(
          onPressed: _updater.requestInstallPermission,
          child: const Text('Allow'),
        ),
        isThreeLine: true,
      ),
    );
  }

  Widget _autoUpdateTile() {
    return SwitchListTile(
      secondary: const Icon(Icons.autorenew),
      title: const Text('Automatic updates'),
      subtitle: const Text(
          'Download new versions automatically when available; you confirm the '
          'final install. Turn off to update only when you tap.'),
      value: _autoUpdate,
      onChanged: _updater.isDevBuild
          ? null
          : (v) async {
              setState(() => _autoUpdate = v);
              await saveAutoUpdate(v);
            },
    );
  }

  Widget _urlSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Update source',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Release API URL',
              helperText: 'Returns the latest-release JSON (tag + APK asset).',
              suffixIcon: IconButton(
                tooltip: 'Save',
                icon: const Icon(Icons.check),
                onPressed: () async {
                  await saveUpdateUrl(_url.text);
                  _toast('Update source saved.');
                  _updater.check();
                },
              ),
            ),
            onSubmitted: (_) async {
              await saveUpdateUrl(_url.text);
              _toast('Update source saved.');
              _updater.check();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                _url.text = kDefaultUpdateApiUrl;
                await saveUpdateUrl(kDefaultUpdateApiUrl);
                _toast('Reset to the default update source.');
                _updater.check();
              },
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reset to default'),
            ),
          ),
        ),
      ],
    );
  }
}
