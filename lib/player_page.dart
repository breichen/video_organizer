import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'store.dart';

/// 1–5 Sterne; erneuter Klick auf die aktuelle Zahl setzt auf 0 zurück.
class StarRating extends StatelessWidget {
  final int rating;
  final ValueChanged<int> onChanged;
  final double size;
  const StarRating({
    super.key,
    required this.rating,
    required this.onChanged,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) => ExcludeFocus(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= 5; i++)
              InkWell(
                onTap: () => onChanged(rating == i ? 0 : i),
                child: Icon(
                  i <= rating ? Icons.star : Icons.star_border,
                  size: size,
                  color: Colors.amber,
                ),
              ),
          ],
        ),
      );
}

class PlayerPage extends StatefulWidget {
  final Store store;
  final String path;
  const PlayerPage({super.key, required this.store, required this.path});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final player = Player();
  late final controller = VideoController(player);

  /// Fokus für die Tastenkürzel (liegt bewusst NICHT über dem Tag-Textfeld).
  final _keys = FocusNode();
  final _tagCtrl = TextEditingController();

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;

  Duration? _start;
  Duration? _end;
  int _rating = 0;

  // Vorschau eines gespeicherten Intervalls: bei Ende pausieren.
  Segment? _active;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    player.open(Media(widget.path), play: false);
    _durSub = player.stream.duration.listen((_) {
      if (mounted) setState(() {});
    });
    _posSub = player.stream.position.listen((pos) {
      final s = _active;
      if (s == null) return;
      if (pos >= s.start && pos < s.end) {
        _armed = true;
      } else if (_armed && pos >= s.end) {
        _active = null;
        _armed = false;
        player.pause();
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    player.dispose();
    _keys.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  Future<void> _seekTo(Duration d) async {
    _active = null;
    final max = player.state.duration;
    if (d < Duration.zero) d = Duration.zero;
    if (max > Duration.zero && d > max) d = max;
    await player.seek(d);
  }

  void _seekRel(int ms) => _seekTo(player.state.position + Duration(milliseconds: ms));

  void _setStart() => setState(() => _start = player.state.position);
  void _setEnd() => setState(() => _end = player.state.position);

  void _addTag(String t) {
    final cur = parseTags(_tagCtrl.text);
    if (!cur.contains(t)) cur.add(t);
    _tagCtrl.text = cur.join(', ');
  }

  void _save() {
    final s = _start, e = _end;
    if (s == null || e == null || e <= s) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Bitte Start und Ende setzen (Ende muss nach dem Start liegen).'),
      ));
      return;
    }
    widget.store.addSegment(Segment(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      videoPath: widget.path,
      startMs: s.inMilliseconds,
      endMs: e.inMilliseconds,
      tags: parseTags(_tagCtrl.text),
      rating: _rating,
    ));
    setState(() {
      _start = null;
      _end = null;
      _rating = 0;
      _tagCtrl.clear();
    });
    _keys.requestFocus();
  }

  Future<void> _playSegment(Segment s) async {
    _armed = false;
    _active = s;
    await player.seek(s.start);
    await player.play();
  }

  Future<void> _editTags(Segment s) async {
    final c = TextEditingController(text: s.tags.join(', '));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tags bearbeiten'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Tags, durch Komma getrennt'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok == true) {
      s.tags = parseTags(c.text);
      await widget.store.changed();
    }
    c.dispose();
    _keys.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(p.basename(widget.path))),
      body: Row(
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.space): player.playOrPause,
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seekRel(-5000),
                const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seekRel(5000),
                const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
                    _seekRel(-1000),
                const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
                    _seekRel(1000),
                const SingleActivator(LogicalKeyboardKey.keyI): _setStart,
                const SingleActivator(LogicalKeyboardKey.keyO): _setEnd,
              },
              child: Focus(
                focusNode: _keys,
                autofocus: true,
                child: _buildPlayer(),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(width: 400, child: _buildSidebar()),
        ],
      ),
    );
  }

  Widget _buildPlayer() => Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                _keys.requestFocus();
                player.playOrPause();
              },
              child: Video(controller: controller, controls: NoVideoControls),
            ),
          ),
          _seekBar(),
          _transport(),
        ],
      );

  Widget _seekBar() => StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (context, snap) {
          final pos = snap.data ?? Duration.zero;
          final dur = player.state.duration;
          final max = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(fmt(pos)),
                Expanded(
                  child: ExcludeFocus(
                    child: Slider(
                      value: pos.inMilliseconds.toDouble().clamp(0.0, max).toDouble(),
                      max: max,
                      onChanged: (v) => _seekTo(Duration(milliseconds: v.round())),
                    ),
                  ),
                ),
                Text(fmt(dur)),
              ],
            ),
          );
        },
      );

  Widget _transport() => ExcludeFocus(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '−5 s (←)',
                icon: const Icon(Icons.replay_5),
                onPressed: () => _seekRel(-5000),
              ),
              StreamBuilder<bool>(
                stream: player.stream.playing,
                initialData: player.state.playing,
                builder: (_, s) => IconButton.filled(
                  tooltip: 'Abspielen / Pause (Leertaste)',
                  iconSize: 32,
                  icon: Icon(s.data! ? Icons.pause : Icons.play_arrow),
                  onPressed: player.playOrPause,
                ),
              ),
              IconButton(
                tooltip: '+5 s (→)',
                icon: const Icon(Icons.forward_5),
                onPressed: () => _seekRel(5000),
              ),
            ],
          ),
        ),
      );

  Widget _buildSidebar() {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final segs = widget.store.segmentsFor(widget.path);
        final tags = widget.store.allTags;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Neues Intervall', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  ExcludeFocus(
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _setStart,
                            child: Text('Start (I): ${_start == null ? '–' : fmt(_start!)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _setEnd,
                            child: Text('Ende (O): ${_end == null ? '–' : fmt(_end!)}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _tagCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tags (durch Komma getrennt)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onTapOutside: (_) => _keys.requestFocus(),
                    onSubmitted: (_) => _save(),
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    ExcludeFocus(
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (final t in tags)
                            ActionChip(label: Text(t), onPressed: () => _addTag(t)),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Bewertung: '),
                      StarRating(rating: _rating, onChanged: (r) => setState(() => _rating = r)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ExcludeFocus(
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.add),
                      label: const Text('Intervall speichern'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: segs.isEmpty
                  ? const Center(child: Text('Noch keine Intervalle.'))
                  : ListView(children: [for (final s in segs) _segmentTile(s)]),
            ),
          ],
        );
      },
    );
  }

  Widget _segmentTile(Segment s) => ExcludeFocus(
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Intervall abspielen',
                  icon: const Icon(Icons.play_circle),
                  onPressed: () => _playSegment(s),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${fmt(s.start)} – ${fmt(s.end)}'),
                      if (s.tags.isNotEmpty)
                        Wrap(
                          spacing: 4,
                          children: [
                            for (final t in s.tags)
                              Chip(label: Text(t), visualDensity: VisualDensity.compact),
                          ],
                        ),
                      StarRating(
                        rating: s.rating,
                        size: 20,
                        onChanged: (r) {
                          s.rating = r;
                          widget.store.changed();
                        },
                      ),
                    ],
                  ),
                ),
                Column(
                  children: [
                    IconButton(
                      tooltip: 'Tags bearbeiten',
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: () => _editTags(s),
                    ),
                    IconButton(
                      tooltip: 'Löschen',
                      icon: const Icon(Icons.delete, size: 20),
                      onPressed: () => widget.store.deleteSegment(s),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
