import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
import 'store.dart';
import 'widgets.dart';

/// Fragt nach einem Namen; null bei Abbruch oder leerem Namen.
Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  // Der Controller wird bewusst nicht von Hand entsorgt: Beim Schließen läuft noch die
  // Ausblend-Animation des Dialogs, die ihn weiter benutzt.
  final c = TextEditingController(text: initial);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
      ],
    ),
  );
  final text = c.text.trim();
  return ok == true && text.isNotEmpty ? text : null;
}

/// Spielt eine Liste von Clips hintereinander ab (zufällig oder eigene Reihenfolge).
class CutPlayerPage extends StatefulWidget {
  final Store store;
  final List<Segment> clips;
  final String title;

  /// 'random' oder 'custom' – wird beim Speichern mitgegeben.
  final String kind;
  final String description;

  /// Wenn gesetzt, gibt es "Neu mischen" (neue zufällige Auswahl).
  final List<Segment> Function()? regenerate;

  const CutPlayerPage({
    super.key,
    required this.store,
    required this.clips,
    required this.title,
    this.kind = 'custom',
    this.description = '',
    this.regenerate,
  });

  @override
  State<CutPlayerPage> createState() => _CutPlayerPageState();
}

class _CutPlayerPageState extends State<CutPlayerPage> {
  final player = Player();
  late final controller = VideoController(player);

  StreamSubscription<Playlist>? _plSub;
  StreamSubscription<bool>? _doneSub;

  late List<Segment> _queue = widget.clips;
  int _index = 0;
  bool _finished = false;
  int _skipped = 0;
  DateTime _lastChange = DateTime.now();

  @override
  void initState() {
    super.initState();
    player.setVolume(widget.store.volume);
    _plSub = player.stream.playlist.listen((pl) {
      if (mounted && pl.index != _index) {
        setState(() {
          _index = pl.index;
          _finished = false;
          _lastChange = DateTime.now();
        });
      }
    });
    // "completed" kommt nach JEDEM Clip (wegen Media.end). Fertig ist der Zusammenschnitt
    // erst nach dem letzten Clip; Meldungen kurz nach einem Clipwechsel gehören noch zum
    // vorherigen Clip.
    _doneSub = player.stream.completed.listen((c) {
      if (!c || !mounted || _queue.isEmpty) return;
      final isLast = _index >= _queue.length - 1;
      final settled =
          DateTime.now().difference(_lastChange) > const Duration(milliseconds: 1000);
      if (isLast && settled) setState(() => _finished = true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _plSub?.cancel();
    _doneSub?.cancel();
    player.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final playable = _queue.where((s) => File(s.videoPath).existsSync()).toList();
    final skipped = _queue.length - playable.length;
    if (!mounted) return;
    setState(() {
      _queue = playable;
      _skipped = skipped;
      _index = 0;
      _finished = false;
      _lastChange = DateTime.now();
    });
    if (playable.isEmpty) return;
    await player.setPlaylistMode(PlaylistMode.none);
    await player.open(
      Playlist([for (final s in playable) Media(s.videoPath, start: s.start, end: s.end)]),
      play: true,
    );
  }

  void _reshuffle() {
    final gen = widget.regenerate;
    if (gen == null) return;
    _queue = gen();
    _start();
  }

  Future<void> _save() async {
    if (_queue.isEmpty) return;
    final suggestion =
        widget.kind == 'random' ? 'Zufall: ${widget.description}' : widget.title;
    final name = await askName(context, title: 'Zusammenschnitt speichern', initial: suggestion);
    if (name == null) return;
    await widget.store.addSavedCut(
      name: name,
      kind: widget.kind,
      clipIds: [for (final s in _queue) s.id],
      description: widget.description,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Gespeichert: „$name“ (Tab „Gespeichert“).')),
    );
  }

  Future<void> _toDraft() async {
    if (_queue.isEmpty) return;
    if (widget.store.draft.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Entwurf ersetzen?'),
          content: const Text('Der aktuelle Entwurf wird durch diese Clips ersetzt.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ersetzen')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await widget.store.setDraft([for (final s in _queue) s.id]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Als Entwurf übernommen – im Tab „Eigener Entwurf“ kannst du ihn bearbeiten.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.regenerate != null)
            IconButton(
              tooltip: 'Neu mischen',
              icon: const Icon(Icons.shuffle),
              onPressed: _reshuffle,
            ),
          IconButton(
            tooltip: 'Als Zusammenschnitt speichern',
            icon: const Icon(Icons.save),
            onPressed: _queue.isEmpty ? null : _save,
          ),
          IconButton(
            tooltip: 'In den Entwurf übernehmen (bearbeiten)',
            icon: const Icon(Icons.edit_note),
            onPressed: _queue.isEmpty ? null : _toDraft,
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: _queue.isEmpty
                      ? Center(
                          child: Text(_skipped > 0
                              ? 'Keine abspielbaren Clips (Dateien nicht gefunden).'
                              : 'Keine Clips.'),
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
                                      Wrap(
                                        spacing: 8,
                                        children: [
                                          FilledButton.icon(
                                            onPressed: _start,
                                            icon: const Icon(Icons.replay),
                                            label: const Text('Nochmal'),
                                          ),
                                          if (widget.regenerate != null)
                                            FilledButton.icon(
                                              onPressed: _reshuffle,
                                              icon: const Icon(Icons.shuffle),
                                              label: const Text('Neu mischen'),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
                if (_queue.isNotEmpty)
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
                        const SizedBox(width: 32),
                        VolumeControl(player: player, store: widget.store),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(width: 320, child: _clipList()),
        ],
      ),
    );
  }

  Widget _clipList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_queue.length} Clips', style: Theme.of(context).textTheme.titleMedium),
              if (widget.description.isNotEmpty)
                Text(widget.description, style: const TextStyle(fontSize: 12)),
              if (_skipped > 0)
                Text(
                  '$_skipped Clips übersprungen (Datei nicht gefunden)',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: _queue.length,
            itemBuilder: (_, i) {
              final s = _queue[i];
              return ListTile(
                dense: true,
                selected: i == _index,
                leading: Text('${i + 1}'),
                title: Text(
                  widget.store.displayName(s.videoPath),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${fmt(s.start)}–${fmt(s.end)}${s.rating > 0 ? ' · ${'★' * s.rating}' : ''}',
                ),
                onTap: () => player.jump(i),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _infoBox() {
    if (_queue.isEmpty) return const SizedBox.shrink();
    final s = _queue[_index.clamp(0, _queue.length - 1)];
    final names = widget.store.performersFor(s.videoPath);
    final who = names.isEmpty ? '' : '${names.join(', ')} · ';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Szene ${_index + 1}/${_queue.length} · ${widget.store.displayName(s.videoPath)}\n'
        '$who${s.tags.join(', ')} · ${'★' * s.rating}  (${fmt(s.start)}–${fmt(s.end)})',
        style: const TextStyle(color: Colors.white),
      ),
    );
  }
}
