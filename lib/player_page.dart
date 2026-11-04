import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
import 'store.dart';
import 'widgets.dart';

int _clampInt(int v, int lo, int hi) => hi < lo ? lo : (v < lo ? lo : (v > hi ? hi : v));

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

  /// Fokus für die Tastenkürzel (liegt bewusst NICHT über den Textfeldern der Seitenleiste).
  final _keys = FocusNode();
  final _tagCtrl = TextEditingController();
  final _vtagCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _perfCtrl = TextEditingController();
  final _seriesCtrl = TextEditingController();
  final _editTagCtrl = TextEditingController();

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;

  // Neues Intervall
  Duration? _start;
  Duration? _end;
  int _rating = 0;

  // Vorschau eines gespeicherten Intervalls: am Ende pausieren.
  Segment? _active;
  bool _armed = false;

  // Bearbeitung eines bestehenden Intervalls
  Segment? _editing;
  String? _editHint;

  @override
  void initState() {
    super.initState();
    _titleCtrl.text = widget.store.titleFor(widget.path);
    _seriesCtrl.text = widget.store.seriesFor(widget.path);
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
    final e = _editing;
    if (e != null) e.tags = parseTags(_editTagCtrl.text);
    widget.store.save();
    _posSub?.cancel();
    _durSub?.cancel();
    player.dispose();
    _keys.dispose();
    _tagCtrl.dispose();
    _vtagCtrl.dispose();
    _titleCtrl.dispose();
    _perfCtrl.dispose();
    _seriesCtrl.dispose();
    _editTagCtrl.dispose();
    super.dispose();
  }

  // ---------- Navigation im Video ----------

  Future<void> _seekTo(Duration d) async {
    _active = null;
    final max = player.state.duration;
    if (d < Duration.zero) d = Duration.zero;
    if (max > Duration.zero && d > max) d = max;
    await player.seek(d);
  }

  void _seekRel(int ms) => _seekTo(player.state.position + Duration(milliseconds: ms));

  /// Pausiert und zeigt das Bild an dieser Stelle im Videofenster.
  Future<void> _showPoint(Duration d, String label) async {
    await player.pause();
    await _seekTo(d);
    if (mounted) setState(() => _editHint = '$label ${fmt(d)}');
  }

  // ---------- Neues Intervall ----------

  void _setStart() {
    if (_editing != null) {
      _setFromCurrent(true);
    } else {
      setState(() => _start = player.state.position);
    }
  }

  void _setEnd() {
    if (_editing != null) {
      _setFromCurrent(false);
    } else {
      setState(() => _end = player.state.position);
    }
  }

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

  // ---------- Bestehendes Intervall bearbeiten ----------

  void _startEditing(Segment s) {
    final prev = _editing;
    if (prev != null) prev.tags = parseTags(_editTagCtrl.text);
    setState(() {
      _editing = s;
      _editTagCtrl.text = s.tags.join(', ');
      _editHint = null;
    });
    _showPoint(s.start, 'Start');
  }

  void _finishEditing() {
    final s = _editing;
    if (s != null) s.tags = parseTags(_editTagCtrl.text);
    setState(() {
      _editing = null;
      _editHint = null;
    });
    widget.store.changed();
    _keys.requestFocus();
  }

  Future<void> _nudge(bool isStart, int deltaMs) async {
    final s = _editing;
    if (s == null) return;
    final dur = player.state.duration.inMilliseconds;
    if (isStart) {
      s.startMs = _clampInt(s.startMs + deltaMs, 0, s.endMs - 100);
    } else {
      s.endMs = _clampInt(
        s.endMs + deltaMs,
        s.startMs + 100,
        dur > 0 ? dur : s.endMs + deltaMs.abs(),
      );
    }
    await widget.store.changed();
    await _showPoint(isStart ? s.start : s.end, isStart ? 'Start' : 'Ende');
  }

  Future<void> _setFromCurrent(bool isStart) async {
    final s = _editing;
    if (s == null) return;
    final pos = player.state.position.inMilliseconds;
    if (isStart ? pos >= s.endMs : pos <= s.startMs) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Der Start muss vor dem Ende liegen.'),
      ));
      return;
    }
    if (isStart) {
      s.startMs = pos;
    } else {
      s.endMs = pos;
    }
    await widget.store.changed();
    if (mounted) {
      setState(() =>
          _editHint = '${isStart ? 'Start' : 'Ende'} ${fmt(Duration(milliseconds: pos))}');
    }
  }

  void _deleteSegment(Segment s) {
    if (identical(_editing, s)) {
      setState(() {
        _editing = null;
        _editHint = null;
      });
    }
    widget.store.deleteSegment(s);
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: widget.store,
          builder: (context, _) => Text(widget.store.displayName(widget.path)),
        ),
      ),
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
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      _keys.requestFocus();
                      player.playOrPause();
                    },
                    child: Video(controller: controller, controls: NoVideoControls),
                  ),
                ),
                if (_editing != null && _editHint != null)
                  Positioned(
                    left: 12,
                    top: 12,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Bearbeite: $_editHint',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
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
              const SizedBox(width: 32),
              VolumeControl(player: player, store: widget.store),
            ],
          ),
        ),
      );

  Widget _buildSidebar() {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final segs = widget.store.segmentsFor(widget.path);
        final editing = _editing;
        return ListView(
          children: [
            _infoSection(context),
            const Divider(height: 1),
            _videoTagsSection(context),
            const Divider(height: 1),
            editing != null ? _editPanel(context, editing) : _newPanel(context),
            const Divider(height: 1),
            if (segs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('Noch keine Intervalle.')),
              )
            else
              for (final s in segs) _segmentTile(s),
          ],
        );
      },
    );
  }

  Future<void> _commitSeries() async {
    await widget.store.commitSeries(widget.path);
    final s = widget.store.seriesFor(widget.path);
    if (mounted && _seriesCtrl.text != s) _seriesCtrl.text = s;
    _keys.requestFocus();
  }

  Widget _infoSection(BuildContext context) {
    final names = widget.store.performersFor(widget.path);
    final all = widget.store.allPerformers;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Video-Infos', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Titel (optional)',
              hintText: 'Standard: Dateiname',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => widget.store.setTitleQuiet(widget.path, v),
            onTapOutside: (_) {
              widget.store.changed();
              _keys.requestFocus();
            },
            onSubmitted: (_) {
              widget.store.changed();
              _keys.requestFocus();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _seriesCtrl,
            decoration: const InputDecoration(
              labelText: 'Serie (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => widget.store.setSeriesQuiet(widget.path, v),
            onTapOutside: (_) => _commitSeries(),
            onSubmitted: (_) => _commitSeries(),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _seriesCtrl,
            builder: (context, value, _) {
              final q = value.text.trim().toLowerCase();
              if (q.isEmpty) return const SizedBox.shrink();
              final matches = widget.store.allSeries
                  .where((s) => s.toLowerCase().contains(q) && s.toLowerCase() != q)
                  .take(6)
                  .toList();
              if (matches.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ExcludeFocus(
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final s in matches)
                        ActionChip(
                          label: Text(s),
                          onPressed: () {
                            _seriesCtrl.text = s;
                            widget.store.setSeriesQuiet(widget.path, s);
                            _commitSeries();
                          },
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Text('DarstellerInnen', style: Theme.of(context).textTheme.labelLarge),
          if (names.isNotEmpty) ...[
            const SizedBox(height: 6),
            ExcludeFocus(
              child: Wrap(
                spacing: 6,
                children: [
                  for (final n in names)
                    InputChip(
                      avatar: const Icon(Icons.person, size: 18),
                      label: Text(n),
                      onDeleted: () => widget.store.removePerformer(widget.path, n),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _perfCtrl,
            decoration: const InputDecoration(
              labelText: 'DarstellerIn hinzufügen (Enter, mehrere mit Komma)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onTapOutside: (_) => _keys.requestFocus(),
            onSubmitted: (v) {
              widget.store.addPerformers(widget.path, parseTags(v));
              _perfCtrl.clear();
              _keys.requestFocus();
            },
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _perfCtrl,
            builder: (context, value, _) {
              final q = value.text.trim().toLowerCase();
              if (q.isEmpty) return const SizedBox.shrink();
              final matches = all
                  .where((n) =>
                      !names.contains(n) &&
                      (n.toLowerCase().contains(q) ||
                          widget.store.aliasesOf(n).any((a) => a.toLowerCase().contains(q))))
                  .take(8)
                  .toList();
              if (matches.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ExcludeFocus(
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final n in matches)
                        ActionChip(
                          avatar: const Icon(Icons.person_add, size: 16),
                          label: Text(n),
                          onPressed: () {
                            widget.store.addPerformers(widget.path, [n]);
                            _perfCtrl.clear();
                          },
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _videoTagsSection(BuildContext context) {
    final tags = widget.store.videoTagsFor(widget.path);
    final suggestions =
        widget.store.allVideoTags.where((t) => !tags.contains(t)).toList();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Video-Tags (für das ganze Video)',
              style: Theme.of(context).textTheme.titleMedium),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 6),
            ExcludeFocus(
              child: Wrap(
                spacing: 6,
                children: [
                  for (final t in tags)
                    InputChip(
                      label: Text(t),
                      onDeleted: () => widget.store.removeVideoTag(widget.path, t),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _vtagCtrl,
            decoration: const InputDecoration(
              labelText: 'Video-Tag hinzufügen (Enter)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onTapOutside: (_) => _keys.requestFocus(),
            onSubmitted: (v) {
              widget.store.addVideoTags(widget.path, parseTags(v));
              _vtagCtrl.clear();
              _keys.requestFocus();
            },
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 6),
            ExcludeFocus(
              child: Wrap(
                spacing: 6,
                children: [
                  for (final t in suggestions)
                    ActionChip(
                      label: Text(t),
                      onPressed: () => widget.store.addVideoTags(widget.path, [t]),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _newPanel(BuildContext context) {
    final tags = widget.store.allTags;
    return Padding(
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
              labelText: 'Szenen-Tags (durch Komma getrennt)',
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
    );
  }

  Widget _editPanel(BuildContext context, Segment s) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Intervall bearbeiten',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              ExcludeFocus(
                child: FilledButton(onPressed: _finishEditing, child: const Text('Fertig')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _timeEditor('Start', s.start, true),
          const SizedBox(height: 8),
          _timeEditor('Ende', s.end, false),
          const SizedBox(height: 8),
          TextField(
            controller: _editTagCtrl,
            decoration: const InputDecoration(
              labelText: 'Szenen-Tags (durch Komma getrennt)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => s.tags = parseTags(v),
            onTapOutside: (_) => _keys.requestFocus(),
            onSubmitted: (_) => _finishEditing(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Bewertung: '),
              StarRating(
                rating: s.rating,
                onChanged: (r) {
                  s.rating = r;
                  widget.store.changed();
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Tipp: Im Video an die gewünschte Stelle gehen und „= aktuelle Position" '
            'drücken – oder I / O.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _timeEditor(String label, Duration t, bool isStart) {
    Widget step(String text, int ms) => OutlinedButton(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          onPressed: () => _nudge(isStart, ms),
          child: Text(text),
        );
    return ExcludeFocus(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('$label: ${fmt(t)}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              IconButton(
                tooltip: 'Zu diesem Punkt springen',
                icon: const Icon(Icons.my_location, size: 20),
                onPressed: () => _showPoint(t, label),
              ),
              TextButton(
                onPressed: () => _setFromCurrent(isStart),
                child: const Text('= aktuelle Position'),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              step('−1 s', -1000),
              step('−0,1 s', -100),
              step('+0,1 s', 100),
              step('+1 s', 1000),
            ],
          ),
        ],
      ),
    );
  }

  Widget _segmentTile(Segment s) {
    final isEditing = identical(_editing, s);
    return ExcludeFocus(
      child: Card(
        color: isEditing ? Theme.of(context).colorScheme.primaryContainer : null,
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
                    tooltip: isEditing ? 'Bearbeitung beenden' : 'Start/Ende/Tags bearbeiten',
                    icon: Icon(isEditing ? Icons.check : Icons.edit, size: 20),
                    onPressed: () => isEditing ? _finishEditing() : _startEditing(s),
                  ),
                  IconButton(
                    tooltip: 'Löschen',
                    icon: const Icon(Icons.delete, size: 20),
                    onPressed: () => _deleteSegment(s),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
