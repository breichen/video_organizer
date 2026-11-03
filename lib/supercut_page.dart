import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'store.dart';

/// Spielt zufällig gemischte, gut bewertete Intervalle zu einem Tag am Stück ab.
class SupercutPage extends StatefulWidget {
  final Store store;
  const SupercutPage({super.key, required this.store});

  @override
  State<SupercutPage> createState() => _SupercutPageState();
}

class _SupercutPageState extends State<SupercutPage> {
  final player = Player();
  late final controller = VideoController(player);

  StreamSubscription<Playlist>? _plSub;
  StreamSubscription<bool>? _doneSub;

  String? _tag;
  int _minRating = 4;
  double _count = 10;

  List<Segment> _queue = [];
  int _index = 0;
  bool _running = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    final tags = widget.store.allTags;
    if (tags.isNotEmpty) _tag = tags.first;
    _plSub = player.stream.playlist.listen((pl) {
      if (_running && mounted && pl.index != _index) setState(() => _index = pl.index);
    });
    _doneSub = player.stream.completed.listen((c) {
      if (c && _running && mounted) setState(() => _finished = true);
    });
  }

  @override
  void dispose() {
    _plSub?.cancel();
    _doneSub?.cancel();
    player.dispose();
    super.dispose();
  }

  List<Segment> get _matches => widget.store.segments
      .where((s) => s.tags.contains(_tag) && s.rating >= _minRating)
      .toList();

  Future<void> _startShow() async {
    final list = _matches.where((s) => File(s.videoPath).existsSync()).toList()..shuffle();
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keine passenden Szenen gefunden.')),
      );
      return;
    }
    setState(() {
      _queue = list.take(_count.round()).toList();
      _index = 0;
      _finished = false;
      _running = true;
    });
    await player.setPlaylistMode(PlaylistMode.none);
    await player.open(
      Playlist([
        for (final s in _queue) Media(s.videoPath, start: s.start, end: s.end),
      ]),
      play: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tags = widget.store.allTags;
    final matches = _tag == null ? 0 : _matches.length;

    return Scaffold(
      appBar: AppBar(title: const Text('Zufalls-Zusammenschnitt')),
      body: tags.isEmpty
          ? const Center(child: Text('Es gibt noch keine Tags. Setze zuerst Intervalle mit Tags.'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 24,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownMenu<String>(
                        label: const Text('Tag'),
                        initialSelection: _tag,
                        dropdownMenuEntries: [
                          for (final t in tags) DropdownMenuEntry(value: t, label: t),
                        ],
                        onSelected: (t) => setState(() => _tag = t),
                      ),
                      SizedBox(
                        width: 260,
                        child: Row(
                          children: [
                            Text('Mind. $_minRating ★'),
                            Expanded(
                              child: Slider(
                                value: _minRating.toDouble(),
                                min: 1,
                                max: 5,
                                divisions: 4,
                                onChanged: (v) => setState(() => _minRating = v.round()),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 280,
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
                      Text('$matches passende Intervalle'),
                      FilledButton.icon(
                        onPressed: matches == 0 ? null : _startShow,
                        icon: const Icon(Icons.shuffle),
                        label: Text(_running ? 'Neu mischen' : 'Zusammenschnitt starten'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: !_running
                      ? const Center(
                          child: Text('Wähle Tag und Mindestbewertung und starte den Zusammenschnitt.'),
                        )
                      : Stack(
                          children: [
                            Positioned.fill(
                              child: Video(controller: controller, controls: NoVideoControls),
                            ),
                            Positioned(left: 12, top: 12, child: _infoBox()),
                            if (_finished)
                              Positioned.fill(
                                child: Container(
                                  color: Colors.black54,
                                  alignment: Alignment.center,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Zusammenschnitt beendet',
                                        style: Theme.of(context).textTheme.headlineSmall,
                                      ),
                                      const SizedBox(height: 12),
                                      FilledButton.icon(
                                        onPressed: _startShow,
                                        icon: const Icon(Icons.shuffle),
                                        label: const Text('Nochmal (neu gemischt)'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
                if (_running)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Vorherige Szene',
                          icon: const Icon(Icons.skip_previous),
                          onPressed: player.previous,
                        ),
                        StreamBuilder<bool>(
                          stream: player.stream.playing,
                          initialData: player.state.playing,
                          builder: (_, s) => IconButton.filled(
                            iconSize: 32,
                            icon: Icon(s.data! ? Icons.pause : Icons.play_arrow),
                            onPressed: player.playOrPause,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Nächste Szene',
                          icon: const Icon(Icons.skip_next),
                          onPressed: player.next,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _infoBox() {
    if (_queue.isEmpty) return const SizedBox.shrink();
    final s = _queue[_index.clamp(0, _queue.length - 1)];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Szene ${_index + 1}/${_queue.length} · ${p.basename(s.videoPath)}\n'
        '${s.tags.join(', ')} · ${'★' * s.rating}  (${fmt(s.start)}–${fmt(s.end)})',
        style: const TextStyle(color: Colors.white),
      ),
    );
  }
}
