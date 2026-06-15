import 'package:flutter/material.dart';

import 'music_player.dart';
import 'music_service.dart';
import 'music_store.dart';

/// Music home: favourites (most played), browse by artist and genre, and
/// search — tapping plays through the shared [MusicPlayer]. A lightweight
/// Spotify-style front-end over the existing music index.
class MusicTab extends StatefulWidget {
  const MusicTab({super.key, required this.music, required this.player});

  final MusicService music;
  final MusicPlayer player;

  @override
  State<MusicTab> createState() => _MusicTabState();
}

class _MusicTabState extends State<MusicTab> {
  MusicStore? _store;
  final TextEditingController _search = TextEditingController();
  List<TrackInfo> _top = const [];
  List<({String name, int count})> _artists = const [];
  List<({String name, int count})> _genres = const [];
  List<({String name, int count})> _folders = const [];
  List<TrackInfo> _searchResults = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayer);
    _open();
  }

  Future<void> _open() async {
    _store = await widget.music.openStore();
    final store = _store!;
    setState(() {
      _top = store.topPlayed(limit: 30);
      _artists = store.artists(limit: 60);
      _genres = store.genres(limit: 40);
      _folders = store.folders(limit: 100);
      _loading = false;
    });
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayer);
    _search.dispose();
    _store?.close();
    super.dispose();
  }

  void _runSearch() {
    final store = _store;
    if (store == null) return;
    final q = _search.text.trim();
    setState(() => _searchResults = q.isEmpty ? const [] : store.resolvePlay(q, limit: 60));
  }

  Future<void> _playList(List<TrackInfo> tracks, {int startAt = 0}) async {
    if (tracks.isEmpty) return;
    await widget.player.playQueue(tracks, startAt: startAt);
  }

  void _openFolder(String folder) {
    final tracks = _store?.byFolder(folder) ?? const [];
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _FolderScreen(
        title: folder,
        tracks: tracks,
        player: widget.player,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_top.isEmpty && _artists.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No music yet. Index your audio library in Settings → Music.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final searching = _search.text.trim().isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: (_) => _runSearch(),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search songs, artists, genres…',
              border: const OutlineInputBorder(),
              suffixIcon: !searching
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        _runSearch();
                      },
                    ),
            ),
          ),
        ),
        if (widget.player.hasMedia) _transport(),
        Expanded(
          child: searching
              ? _trackList(_searchResults)
              : ListView(
                  children: [
                    _header('Favourites · most played'),
                    if (_top.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Play some songs and they\'ll show here.',
                            style: TextStyle(color: Colors.grey)),
                      )
                    else
                      for (var i = 0; i < _top.length; i++)
                        _trackTile(_top[i], () => _playList(_top, startAt: i)),
                    if (_folders.isNotEmpty) ...[
                      _header('Folders'),
                      for (final f in _folders)
                        ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(f.name),
                          subtitle: Text('${f.count} track${f.count == 1 ? '' : 's'}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openFolder(f.name),
                        ),
                    ],
                    if (_genres.isNotEmpty) ...[
                      _header('Genres'),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final g in _genres)
                              ActionChip(
                                label: Text('${g.name} (${g.count})'),
                                onPressed: () =>
                                    _playList(_store!.byGenre(g.name)),
                              ),
                          ],
                        ),
                      ),
                    ],
                    if (_artists.isNotEmpty) ...[
                      _header('Artists'),
                      for (final a in _artists)
                        ListTile(
                          leading: const Icon(Icons.person_outline),
                          title: Text(a.name),
                          subtitle: Text('${a.count} track${a.count == 1 ? '' : 's'}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.play_arrow),
                            onPressed: () => _playList(_store!.byArtist(a.name)),
                          ),
                          onTap: () => _playList(_store!.byArtist(a.name)),
                        ),
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(text,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary)),
      );

  Widget _trackList(List<TrackInfo> tracks) {
    if (tracks.isEmpty) {
      return const Center(child: Text('No matches.'));
    }
    return ListView(
      children: [
        for (var i = 0; i < tracks.length; i++)
          _trackTile(tracks[i], () => _playList(tracks, startAt: i)),
      ],
    );
  }

  Widget _trackTile(TrackInfo t, VoidCallback onPlay) {
    final playing = widget.player.current?.id == t.id && !widget.player.isRadio;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: Icon(playing ? Icons.equalizer : Icons.music_note,
          color: playing ? scheme.primary : null),
      title: Text(t.title.isNotEmpty ? t.title : t.path.split('/').last,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (t.artist.isNotEmpty) t.artist,
          if (t.playCount > 0) '${t.playCount} play${t.playCount == 1 ? '' : 's'}',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onPlay,
    );
  }

  Widget _transport() {
    final p = widget.player;
    final scheme = Theme.of(context).colorScheme;
    final t = p.current;
    final title = t?.title.isNotEmpty == true
        ? t!.title
        : (t?.path.split('/').last ?? 'Playing');
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(Icons.music_note, color: scheme.onSecondaryContainer, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSecondaryContainer)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.skip_previous, color: scheme.onSecondaryContainer),
              onPressed: p.previous,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(p.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: scheme.onSecondaryContainer),
              onPressed: p.toggle,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.skip_next, color: scheme.onSecondaryContainer),
              onPressed: p.next,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
              onPressed: p.stop,
            ),
          ],
        ),
      ),
    );
  }
}

/// A folder's tracks, with a "Play all" and per-track play. Listens to the
/// player so the currently-playing track is highlighted.
class _FolderScreen extends StatefulWidget {
  const _FolderScreen({
    required this.title,
    required this.tracks,
    required this.player,
  });

  final String title;
  final List<TrackInfo> tracks;
  final MusicPlayer player;

  @override
  State<_FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<_FolderScreen> {
  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayer);
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Play all',
            icon: const Icon(Icons.play_circle_fill),
            onPressed: widget.tracks.isEmpty
                ? null
                : () => widget.player.playQueue(widget.tracks),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: widget.tracks.length,
        itemBuilder: (context, i) {
          final t = widget.tracks[i];
          final playing =
              widget.player.current?.id == t.id && !widget.player.isRadio;
          return ListTile(
            dense: true,
            leading: Icon(playing ? Icons.equalizer : Icons.music_note,
                color: playing ? scheme.primary : null),
            title: Text(t.title.isNotEmpty ? t.title : t.path.split('/').last,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [if (t.artist.isNotEmpty) t.artist, if (t.album.isNotEmpty) t.album]
                  .join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => widget.player.playQueue(widget.tracks, startAt: i),
          );
        },
      ),
    );
  }
}
