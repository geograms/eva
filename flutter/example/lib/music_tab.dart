import 'package:flutter/material.dart';

import 'music_meta.dart';
import 'music_player.dart';
import 'music_service.dart';
import 'music_store.dart';

/// Music home: a search field plus three sub-tabs — Favourites (most played),
/// Folders (grouped by genre → folder), and Artists — so no single list gets
/// too long. Plays through the shared [MusicPlayer].
class MusicTab extends StatefulWidget {
  const MusicTab({super.key, required this.music, required this.player});

  final MusicService music;
  final MusicPlayer player;

  @override
  State<MusicTab> createState() => _MusicTabState();
}

class _MusicTabState extends State<MusicTab> with TickerProviderStateMixin {
  MusicStore? _store;
  late final TabController _subTab = TabController(length: 3, vsync: this);
  final TextEditingController _search = TextEditingController();
  List<TrackInfo> _top = const [];
  List<({String name, int count})> _artists = const [];
  List<({String name, int count})> _folders = const [];
  Map<String, MusicFolderMeta> _folderMeta = {};
  List<TrackInfo> _searchResults = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayer);
    musicCategorizeProgress.addListener(_onMusicCat);
    _open();
  }

  Future<void> _open() async {
    _store = await widget.music.openStore();
    final store = _store!;
    final meta = await MusicMetaStore.all();
    if (!mounted) return;
    setState(() {
      _top = store.topPlayed(limit: 60);
      _artists = store.artists(limit: 200);
      _folders = store.folders(limit: 1000);
      _folderMeta = meta;
      _loading = false;
    });
  }

  // Refresh as folders get their genre, so they move out of "To categorize".
  Future<void> _onMusicCat() async {
    final meta = await MusicMetaStore.all();
    if (mounted) setState(() => _folderMeta = meta);
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayer);
    musicCategorizeProgress.removeListener(_onMusicCat);
    _subTab.dispose();
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

  void _openTracks(String title, List<TrackInfo> tracks) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _TrackListScreen(
        title: title,
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
        if (searching)
          Expanded(child: _trackList(_searchResults))
        else ...[
          TabBar(
            controller: _subTab,
            tabs: const [
              Tab(text: 'Favourites'),
              Tab(text: 'Folders'),
              Tab(text: 'Artists'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _subTab,
              children: [
                _favouritesPage(),
                _foldersPage(),
                _artistsPage(),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _favouritesPage() {
    if (_top.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Play some songs and your favourites will show here.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return ListView.builder(
      itemCount: _top.length,
      itemBuilder: (context, i) => _trackTile(_top[i], () => _playList(_top, startAt: i)),
    );
  }

  Widget _artistsPage() {
    if (_artists.isEmpty) {
      return const Center(child: Text('No tagged artists.'));
    }
    return ListView.builder(
      itemCount: _artists.length,
      itemBuilder: (context, i) {
        final a = _artists[i];
        return ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(a.name),
          subtitle: Text('${a.count} track${a.count == 1 ? '' : 's'}'),
          trailing: IconButton(
            icon: const Icon(Icons.play_arrow),
            onPressed: () => _playList(_store!.byArtist(a.name)),
          ),
          onTap: () => _openTracks(a.name, _store!.byArtist(a.name, limit: 500)),
        );
      },
    );
  }

  /// Folders grouped by their LLM-assigned genre → subgenre → folder. Folders
  /// not yet categorised go under "To categorize" with live progress.
  Widget _foldersPage() {
    if (_folders.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No folders found. Music files need a containing folder.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    const toDo = 'To categorize';
    // genre → subgenre → [(folder,count)]
    final tree = <String, Map<String, List<({String name, int count})>>>{};
    for (final f in _folders) {
      final m = _folderMeta[f.name];
      final String genre;
      final String sub;
      if (m == null || !m.categorized) {
        genre = toDo;
        sub = '';
      } else {
        genre = m.genre.isNotEmpty ? m.genre : 'Other';
        sub = m.subgenre;
      }
      (tree.putIfAbsent(genre, () => {}).putIfAbsent(sub, () => [])).add(f);
    }
    final genres = tree.keys.toList()
      ..sort((a, b) {
        if (a == toDo) return 1;
        if (b == toDo) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return ListView(
      children: [
        for (final genre in genres)
          ExpansionTile(
            leading: Icon(genre == toDo ? Icons.hourglass_empty : Icons.library_music_outlined),
            initiallyExpanded: genre == toDo && genres.length == 1,
            title: Text(genre),
            subtitle: genre == toDo
                ? _toCategorizeSubtitle(tree[genre]!.values.fold<int>(0, (s, l) => s + l.length))
                : Text('${tree[genre]!.values.fold<int>(0, (s, l) => s + l.length)} folders'),
            childrenPadding: const EdgeInsets.only(left: 8),
            children: [
              for (final sub in (tree[genre]!.keys.toList()..sort()))
                if (sub.isEmpty)
                  for (final f in tree[genre]![sub]!) _folderTile(f)
                else
                  ExpansionTile(
                    leading: const Icon(Icons.subdirectory_arrow_right),
                    title: Text(sub),
                    subtitle: Text('${tree[genre]![sub]!.length} folders'),
                    childrenPadding: const EdgeInsets.only(left: 8),
                    children: [for (final f in tree[genre]![sub]!) _folderTile(f)],
                  ),
            ],
          ),
      ],
    );
  }

  Widget _folderTile(({String name, int count}) f) => ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: Text(f.name),
        subtitle: Text('${f.count} track${f.count == 1 ? '' : 's'}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openTracks(f.name, _store!.byFolder(f.name)),
      );

  Widget _toCategorizeSubtitle(int count) =>
      ValueListenableBuilder<({int done, int total})>(
        valueListenable: musicCategorizeProgress,
        builder: (context, p, _) {
          if (p.total > 0) {
            return Text('Categorising ${p.done} of ${p.total}…',
                style: TextStyle(color: Theme.of(context).colorScheme.primary));
          }
          return Text('$count folder${count == 1 ? '' : 's'} · categorising as '
              'you browse and while charging');
        },
      );

  Widget _trackList(List<TrackInfo> tracks) {
    if (tracks.isEmpty) return const Center(child: Text('No matches.'));
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) =>
          _trackTile(tracks[i], () => _playList(tracks, startAt: i)),
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

/// A list of tracks (a folder or an artist), with Play-all and per-track play.
class _TrackListScreen extends StatefulWidget {
  const _TrackListScreen({
    required this.title,
    required this.tracks,
    required this.player,
  });

  final String title;
  final List<TrackInfo> tracks;
  final MusicPlayer player;

  @override
  State<_TrackListScreen> createState() => _TrackListScreenState();
}

class _TrackListScreenState extends State<_TrackListScreen> {
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
