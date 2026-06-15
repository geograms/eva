import 'package:flutter/material.dart';

import 'music_player.dart';
import 'music_service.dart';
import 'playlist_store.dart';

/// Full-screen player: now-playing info, a seek bar, transport + shuffle, the
/// current playlist (tap to play, remove, add more), and save/load/delete of
/// named playlists.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.player, required this.music});

  final MusicPlayer player;
  final MusicService music;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.player.removeListener(_onChange);
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final scheme = Theme.of(context).colorScheme;
    final t = p.current;
    final radio = p.isRadio;
    final title = radio
        ? (p.radioName ?? 'Radio')
        : (t?.title.isNotEmpty == true ? t!.title : (t?.path.split('/').last ?? 'Nothing playing'));
    final subtitle = radio ? 'Live radio' : (t?.artist ?? '');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Now playing'),
        actions: [
          if (!radio && p.queueLength > 0)
            IconButton(
              tooltip: 'Save as playlist',
              icon: const Icon(Icons.playlist_add),
              onPressed: _saveAsPlaylist,
            ),
          IconButton(
            tooltip: 'Playlists',
            icon: const Icon(Icons.queue_music),
            onPressed: _openPlaylists,
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          Icon(radio ? Icons.radio : Icons.album,
              size: 96, color: scheme.primary.withValues(alpha: 0.7)),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Text(title,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge),
          ),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          if (!radio) _seekBar(),
          _controls(),
          const Divider(height: 1),
          Expanded(child: _queueList()),
        ],
      ),
    );
  }

  Widget _seekBar() {
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        final dur = widget.player.duration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final value = max <= 0 ? 0.0 : pos.inMilliseconds.clamp(0, max).toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            children: [
              Slider(
                value: value,
                max: max <= 0 ? 1 : max,
                onChanged: max <= 0
                    ? null
                    : (v) => widget.player.seek(Duration(milliseconds: v.round())),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(pos), style: Theme.of(context).textTheme.labelSmall),
                    Text(_fmt(dur), style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _controls() {
    final p = widget.player;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Shuffle',
            iconSize: 26,
            icon: Icon(Icons.shuffle,
                color: p.shuffleEnabled ? scheme.primary : scheme.onSurfaceVariant),
            onPressed: p.isRadio ? null : p.toggleShuffle,
          ),
          IconButton(
            iconSize: 36,
            icon: const Icon(Icons.skip_previous),
            onPressed: p.isRadio ? null : p.previous,
          ),
          IconButton.filled(
            iconSize: 40,
            icon: Icon(p.isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: p.toggle,
          ),
          IconButton(
            iconSize: 36,
            icon: const Icon(Icons.skip_next),
            onPressed: p.isRadio ? null : p.next,
          ),
          IconButton(
            tooltip: 'Stop',
            iconSize: 26,
            icon: const Icon(Icons.stop),
            onPressed: p.stop,
          ),
        ],
      ),
    );
  }

  Widget _queueList() {
    final p = widget.player;
    if (p.isRadio || p.queueLength == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(p.isRadio ? 'Live radio — no playlist.' : 'The playlist is empty.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final q = p.queue;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: q.length,
      itemBuilder: (context, i) {
        final t = q[i];
        final playing = i == p.index;
        return ListTile(
          dense: true,
          leading: Icon(playing ? Icons.equalizer : Icons.drag_handle,
              color: playing ? scheme.primary : scheme.onSurfaceVariant),
          title: Text(t.title.isNotEmpty ? t.title : t.path.split('/').last,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: t.artist.isEmpty
              ? null
              : Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => p.removeFromQueue(i),
          ),
          onTap: () => p.playAt(i),
        );
      },
    );
  }

  Future<void> _saveAsPlaylist() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save playlist'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await PlaylistStore.save(name, [for (final t in widget.player.queue) t.path]);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved playlist "${name.trim()}"')));
    }
  }

  Future<void> _openPlaylists() async {
    final map = await PlaylistStore.all();
    if (!mounted) return;
    if (map.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No saved playlists yet. Save the current one first.')));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Saved playlists', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final entry in map.entries)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(entry.key),
              subtitle: Text('${entry.value.length} tracks'),
              onTap: () {
                Navigator.pop(ctx);
                _loadPlaylist(entry.key, entry.value);
              },
              trailing: IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await PlaylistStore.delete(entry.key);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _loadPlaylist(String name, List<String> paths) async {
    final store = await widget.music.openStore();
    try {
      final tracks = store.tracksByPaths(paths);
      if (tracks.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Those tracks are no longer in the library.')));
        }
        return;
      }
      await widget.player.playQueue(tracks);
    } finally {
      store.close();
    }
  }
}
