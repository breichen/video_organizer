import 'package:flutter/material.dart';

import 'clip_filter.dart';
import 'cut_player_page.dart';
import 'cuts_tabs.dart';
import 'models.dart';
import 'player_page.dart';
import 'store.dart';
import 'thumb_widgets.dart';
import 'widgets.dart';

/// Clips & Zusammenschnitte: Übersicht, Zufall, eigener Entwurf, gespeicherte.
/// Die Filter gelten gemeinsam für Übersicht und Zufall.
class CutsHubPage extends StatefulWidget {
  final Store store;
  final int initialTab;
  final ClipFilter? initialFilter;

  const CutsHubPage({
    super.key,
    required this.store,
    this.initialTab = 0,
    this.initialFilter,
  });

  @override
  State<CutsHubPage> createState() => _CutsHubPageState();
}

class _CutsHubPageState extends State<CutsHubPage> {
  late final ClipFilter _filter = widget.initialFilter ?? ClipFilter();

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Clips & Zusammenschnitte'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Clip-Übersicht'),
              Tab(text: 'Zufällig'),
              Tab(text: 'Eigener Entwurf'),
              Tab(text: 'Gespeichert'),
            ],
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            ClipsTab(store: widget.store, filter: _filter, onFilterChanged: _changed),
            RandomTab(store: widget.store, filter: _filter, onFilterChanged: _changed),
            DraftTab(store: widget.store),
            SavedTab(store: widget.store),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Clip-Übersicht
// ---------------------------------------------------------------------------

class ClipsTab extends StatefulWidget {
  final Store store;
  final ClipFilter filter;
  final VoidCallback onFilterChanged;
  const ClipsTab({
    super.key,
    required this.store,
    required this.filter,
    required this.onFilterChanged,
  });

  @override
  State<ClipsTab> createState() => _ClipsTabState();
}

class _ClipsTabState extends State<ClipsTab> {
  String _sort = 'video';

  List<Segment> _sorted(List<Segment> list) {
    final store = widget.store;
    int byName(Segment a, Segment b) {
      final c = store
          .displayName(a.videoPath)
          .toLowerCase()
          .compareTo(store.displayName(b.videoPath).toLowerCase());
      return c != 0 ? c : a.startMs.compareTo(b.startMs);
    }

    switch (_sort) {
      case 'rating':
        list.sort((a, b) {
          final c = b.rating.compareTo(a.rating);
          return c != 0 ? c : byName(a, b);
        });
      case 'newest':
        list.sort((a, b) => (int.tryParse(b.id) ?? 0).compareTo(int.tryParse(a.id) ?? 0));
      default:
        list.sort(byName);
    }
    return list;
  }

  void _openInPlayer(Segment s) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            store: widget.store,
            path: s.videoPath,
            initialSegment: s,
          ),
        ),
      );

  Widget _clipTile(Segment s) {
    final store = widget.store;
    final inDraft = store.draft.contains(s.id);
    final people = store.performersFor(s.videoPath);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Tooltip(
          message: 'Im Player ansehen',
          child: GestureDetector(
            onTap: () => _openInPlayer(s),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ClipThumb(
                store: store,
                segment: s,
                overlay: const Center(
                  child: Icon(Icons.play_circle, color: Colors.white70, size: 28),
                ),
              ),
            ),
          ),
        ),
        title: Text('${store.displayName(s.videoPath)}  ·  ${fmt(s.start)}–${fmt(s.end)}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (s.tags.isNotEmpty)
              Wrap(
                spacing: 4,
                children: [
                  for (final t in s.tags)
                    Chip(label: Text(t), visualDensity: VisualDensity.compact),
                ],
              ),
            if (people.isNotEmpty)
              Text(people.join(', '), style: const TextStyle(fontStyle: FontStyle.italic)),
            StarRating(
              rating: s.rating,
              size: 18,
              onChanged: (r) {
                s.rating = r;
                store.changed();
              },
            ),
          ],
        ),
        trailing: IconButton(
          tooltip: inDraft ? 'Aus dem Entwurf entfernen' : 'Zum Entwurf hinzufügen',
          icon: Icon(inDraft ? Icons.playlist_add_check : Icons.playlist_add),
          onPressed: () => store.draftToggle(s.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final clips = _sorted(widget.filter.apply(widget.store));
        final total = Duration(
          milliseconds: clips.fold<int>(0, (a, s) => a + (s.endMs - s.startMs)),
        );
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: ClipFilterBar(
                store: widget.store,
                filter: widget.filter,
                onChanged: widget.onFilterChanged,
                extra: [
                  DropdownMenu<String>(
                    key: ValueKey('sort:$_sort'),
                    width: 220,
                    label: const Text('Sortierung'),
                    initialSelection: _sort,
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(value: 'video', label: 'Video & Zeit'),
                      DropdownMenuEntry(value: 'rating', label: 'Bewertung'),
                      DropdownMenuEntry(value: 'newest', label: 'Neueste zuerst'),
                    ],
                    onSelected: (v) => setState(() => _sort = v ?? 'video'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(child: Text('${clips.length} Clips · ≈ ${fmtShort(total)}')),
                  OutlinedButton.icon(
                    onPressed: clips.isEmpty
                        ? null
                        : () => widget.store.draftAdd(clips.map((s) => s.id)),
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Alle zum Entwurf'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: clips.isEmpty
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => CutPlayerPage(
                                  store: widget.store,
                                  clips: clips,
                                  title: 'Clip-Übersicht',
                                  description: widget.filter.describe(),
                                ),
                              ),
                            ),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Alle abspielen'),
                  ),
                ],
              ),
            ),
            const Divider(height: 16),
            Expanded(
              child: clips.isEmpty
                  ? const Center(child: Text('Keine passenden Clips.'))
                  : ListView.builder(
                      itemCount: clips.length,
                      itemBuilder: (_, i) => _clipTile(clips[i]),
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Zufälliger Zusammenschnitt
// ---------------------------------------------------------------------------

class RandomTab extends StatefulWidget {
  final Store store;
  final ClipFilter filter;
  final VoidCallback onFilterChanged;
  const RandomTab({
    super.key,
    required this.store,
    required this.filter,
    required this.onFilterChanged,
  });

  @override
  State<RandomTab> createState() => _RandomTabState();
}

class _RandomTabState extends State<RandomTab> {
  double _count = 10;

  List<Segment> _generate() {
    final list = widget.filter.apply(widget.store)..shuffle();
    return list.take(_count.round()).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final matches = widget.filter.apply(widget.store).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: ClipFilterBar(
                store: widget.store,
                filter: widget.filter,
                onChanged: widget.onFilterChanged,
                extra: [
                  SizedBox(
                    width: 300,
                    child: Row(
                      children: [
                        Text('Szenen: ${_count.round()}'),
                        Expanded(
                          child: Slider(
                            value: _count,
                            min: 3,
                            max: 30,
                            divisions: 27,
                            onChanged: (v) => setState(() => _count = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(child: Text('$matches passende Clips')),
                  FilledButton.icon(
                    onPressed: matches == 0
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => CutPlayerPage(
                                  store: widget.store,
                                  clips: _generate(),
                                  title: 'Zufälliger Zusammenschnitt',
                                  kind: 'random',
                                  description: widget.filter.describe(),
                                  regenerate: _generate,
                                ),
                              ),
                            ),
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Zusammenschnitt starten'),
                  ),
                ],
              ),
            ),
            const Divider(height: 24),
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Zufällige Auswahl aus den passenden Clips. Im Player kannst du den '
                    'Zusammenschnitt speichern oder als Entwurf übernehmen und bearbeiten.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
