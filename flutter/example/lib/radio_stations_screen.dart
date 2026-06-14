import 'package:flutter/material.dart';

import 'app_prefs.dart';
import 'music_player.dart';

/// Manage the list of online radio stations: add, edit, delete, reorder-free
/// list, and play one straight from here. Seeded with example stations on first
/// open (see [kDefaultRadioStations]).
class RadioStationsScreen extends StatefulWidget {
  const RadioStationsScreen({super.key, required this.player});

  final MusicPlayer player;

  @override
  State<RadioStationsScreen> createState() => _RadioStationsScreenState();
}

class _RadioStationsScreenState extends State<RadioStationsScreen> {
  List<RadioStation> _stations = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await loadRadioStations();
    if (mounted) {
      setState(() {
        _stations = s;
        _loading = false;
      });
    }
  }

  Future<void> _persist() async {
    await saveRadioStations(_stations);
    if (mounted) setState(() {});
  }

  Future<void> _play(RadioStation s) async {
    await widget.player.playRadio(s.name, s.url);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('▶ Tuning in to ${s.name}…')));
    }
  }

  Future<void> _edit({RadioStation? existing, int? index}) async {
    final result = await showDialog<RadioStation>(
      context: context,
      builder: (_) => _StationDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      final list = List<RadioStation>.of(_stations);
      if (index != null) {
        list[index] = result;
      } else {
        list.add(result);
      }
      _stations = list;
    });
    await _persist();
  }

  Future<void> _delete(int index) async {
    final removed = _stations[index];
    setState(() {
      final list = List<RadioStation>.of(_stations)..removeAt(index);
      _stations = list;
    });
    await _persist();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Removed ${removed.name}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            setState(() {
              final list = List<RadioStation>.of(_stations)
                ..insert(index.clamp(0, _stations.length), removed);
              _stations = list;
            });
            await _persist();
          },
        ),
      ));
    }
  }

  Future<void> _restoreDefaults() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore example stations'),
        content: const Text(
            'Add the built-in example stations back to your list? Your own '
            'stations are kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    final urls = _stations.map((s) => s.url).toSet();
    setState(() {
      final list = List<RadioStation>.of(_stations);
      for (final d in kDefaultRadioStations) {
        if (!urls.contains(d.url)) list.add(d);
      }
      _stations = list;
    });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio stations'),
        actions: [
          IconButton(
            tooltip: 'Restore examples',
            icon: const Icon(Icons.restore),
            onPressed: _restoreDefaults,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add station'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _stations.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No stations yet. Add one with the button below, or '
                      'restore the examples from the top-right.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: _stations.length,
                  separatorBuilder: (context, i) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final s = _stations[i];
                    final playing =
                        widget.player.isRadio && widget.player.radioName == s.name;
                    return ListTile(
                      leading: Icon(playing ? Icons.equalizer : Icons.radio,
                          color: playing
                              ? Theme.of(context).colorScheme.primary
                              : null),
                      title: Text(s.name),
                      subtitle: Text(
                        s.genre.isNotEmpty ? '${s.genre}\n${s.url}' : s.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      isThreeLine: s.genre.isNotEmpty,
                      onTap: () => _play(s),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Play',
                            icon: const Icon(Icons.play_arrow),
                            onPressed: () => _play(s),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'edit') {
                                _edit(existing: s, index: i);
                              } else if (v == 'delete') {
                                _delete(i);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

/// Add/edit dialog for a single station.
class _StationDialog extends StatefulWidget {
  const _StationDialog({this.existing});
  final RadioStation? existing;

  @override
  State<_StationDialog> createState() => _StationDialogState();
}

class _StationDialogState extends State<_StationDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _url =
      TextEditingController(text: widget.existing?.url ?? '');
  late final TextEditingController _genre =
      TextEditingController(text: widget.existing?.genre ?? '');
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _genre.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = 'Name and stream URL are required.');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      setState(() => _error = 'The URL must start with http:// or https://');
      return;
    }
    Navigator.pop(
        context, RadioStation(name: name, url: url, genre: _genre.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add station' : 'Edit station'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                  labelText: 'Stream URL', hintText: 'https://…'),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            TextField(
              controller: _genre,
              decoration:
                  const InputDecoration(labelText: 'Genre (optional)'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
