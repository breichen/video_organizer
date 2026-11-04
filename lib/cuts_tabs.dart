import 'package:flutter/material.dart';

import 'cut_player_page.dart';
import 'models.dart';
import 'player_page.dart';
import 'store.dart';
import 'thumb_widgets.dart';

String _fmtDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String t(int n) => n.toString().padLeft(2, '0');
  return '${t(d.day)}.${t(d.month)}.${d.year} ${t(d.hour)}:${t(d.minute)}';
}

Duration _totalOf(List<Segment> clips) =>
    Duration(milliseconds: clips.fold<int>(0, (a, s) => a + (s.endMs - s.startMs)));

// ---------------------------------------------------------------------------
// Eigener Entwurf
// ---------------------------------------------------------------------------

class DraftTab extends StatefulWidget {
  final Store store;
  const DraftTab({super.key, required this.store});

  @override
  State<DraftTab> createState() => _DraftTabState();
}

class _DraftTabState extends State<DraftTab> {
  final _nameCtrl = TextEditingController();
  int _serial = -1;

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    _sync();
    store.addListener(_sync);
  }

  /// Übernimmt den Namen, wenn der Entwurf ersetzt wurde (z. B. beim Bearbeiten).
  void _sync() {
    if (_serial != store.draftSerial) {
      _serial = store.draftSerial;
      _nameCtrl.text = store.draftName;
    }
  }

  @override
  void dispose() {
    store.removeListener(_sync);
    store.draftName = _nameCtrl.text.trim();
    store.save();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _openInPlayer(Segment s) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(store: store, path: s.videoPath, initialSegment: s),
        ),
      );

  void _play(List<Segment> clips) {
    final name = _nameCtrl.text.trim();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CutPlayerPage(
          store: store,
          clips: clips,
          title: name.isEmpty ? 'Eigener Zusammenschnitt' : name,
        ),
      ),
    );
  }

  Future<void> _save({bool asNew = false}) async {
    if (store.draftClips().isEmpty) return;
    var name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      name = await askName(context, title: 'Name des Zusammenschnitts') ?? '';
      if (name.isEmpty) return;
      _nameCtrl.text = name;
    }
    store.draftName = name;
    await store.saveDraft(name: name, asNew: asNew);
    if (mounted) _snack('Gespeichert: „$name“.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final clips = store.draftClips();
        final editing = store.draftCutId == null
            ? null
            : store.savedCuts.where((c) => c.id == store.draftCutId).firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    editing != null
                        ? 'Bearbeite „${editing.name}“'
                        : 'Neuer eigener Zusammenschnitt',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => store.draftName = v,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: clips.isEmpty ? null : () => _play(clips),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Abspielen'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: clips.isEmpty ? null : () => _save(),
                        icon: const Icon(Icons.save),
                        label: Text(editing != null ? 'Änderungen speichern' : 'Speichern'),
                      ),
                      if (editing != null)
                        OutlinedButton.icon(
                          onPressed: clips.isEmpty ? null : () => _save(asNew: true),
                          icon: const Icon(Icons.save_as),
                          label: const Text('Als neu speichern'),
                        ),
                      OutlinedButton.icon(
                        onPressed: clips.length < 2 ? null : store.draftShuffle,
                        icon: const Icon(Icons.shuffle),
                        label: const Text('Reihenfolge mischen'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => DefaultTabController.of(context).animateTo(0),
                        icon: const Icon(Icons.add),
                        label: const Text('Clips hinzufügen'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            (clips.isEmpty && editing == null) ? null : () => store.setDraft([]),
                        icon: const Icon(Icons.clear_all),
                        label: const Text('Neuer Entwurf'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('${clips.length} Clips · ≈ ${fmtShort(_totalOf(clips))}'),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: clips.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Der Entwurf ist leer. Füge in der Clip-Übersicht Clips mit dem '
                          '„+“-Symbol hinzu und bringe sie hier in die gewünschte Reihenfolge.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: clips.length,
                      onReorder: (o, n) => store.draftMove(o, n),
                      itemBuilder: (context, i) {
                        final s = clips[i];
                        final info = [
                          if (s.tags.isNotEmpty) s.tags.join(', '),
                          if (s.rating > 0) '★' * s.rating,
                        ].join(' · ');
                        return ListTile(
                          key: ValueKey(s.id),
                          leading: ReorderableDragStartListener(
                            index: i,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.drag_handle),
                                const SizedBox(width: 8),
                                ClipThumb(store: store, segment: s, width: 80, height: 45),
                              ],
                            ),
                          ),
                          title: Text(
                            '${i + 1}. ${store.displayName(s.videoPath)}  ·  '
                            '${fmt(s.start)}–${fmt(s.end)}',
                          ),
                          subtitle: info.isEmpty ? null : Text(info),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Im Player ansehen',
                                icon: const Icon(Icons.play_circle),
                                onPressed: () => _openInPlayer(s),
                              ),
                              IconButton(
                                tooltip: 'Aus dem Entwurf entfernen',
                                icon: const Icon(Icons.close),
                                onPressed: () => store.draftRemoveAt(i),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Gespeicherte Zusammenschnitte
// ---------------------------------------------------------------------------

class SavedTab extends StatelessWidget {
  final Store store;
  const SavedTab({super.key, required this.store});

  void _play(BuildContext context, SavedCut cut) {
    final clips = store.resolveClips(cut.clipIds);
    if (clips.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alle Clips dieses Zusammenschnitts wurden gelöscht.')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CutPlayerPage(
          store: store,
          clips: clips,
          title: cut.name,
          kind: cut.kind,
          description: cut.description,
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, SavedCut cut) async {
    await store.setDraft(cut.clipIds, cutId: cut.id, name: cut.name);
    if (context.mounted) DefaultTabController.of(context).animateTo(2);
  }

  Future<void> _rename(BuildContext context, SavedCut cut) async {
    final name = await askName(context, title: 'Umbenennen', initial: cut.name);
    if (name != null) await store.renameSavedCut(cut.id, name);
  }

  Future<void> _delete(BuildContext context, SavedCut cut) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('„${cut.name}“ löschen?'),
        content: const Text('Die Clips selbst bleiben erhalten.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true) await store.deleteSavedCut(cut.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final cuts = [...store.savedCuts]..sort((a, b) => b.createdMs.compareTo(a.createdMs));
        if (cuts.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Noch keine gespeicherten Zusammenschnitte.\n'
                'Speichere einen zufälligen Zusammenschnitt im Player oder erstelle einen Entwurf.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.builder(
          itemCount: cuts.length,
          itemBuilder: (_, i) {
            final cut = cuts[i];
            final clips = store.resolveClips(cut.clipIds);
            final missing = cut.clipIds.length - clips.length;
            final lines = [
              '${clips.length} Clips · ≈ ${fmtShort(_totalOf(clips))} · ${_fmtDate(cut.createdMs)}'
                  '${missing > 0 ? ' · $missing nicht mehr vorhanden' : ''}',
              if (cut.description.isNotEmpty) cut.description,
            ];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: Icon(cut.kind == 'random' ? Icons.shuffle : Icons.edit_note),
                title: Text(cut.name),
                subtitle: Text(lines.join('\n')),
                isThreeLine: lines.length > 1,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Abspielen',
                      icon: const Icon(Icons.play_circle),
                      onPressed: () => _play(context, cut),
                    ),
                    IconButton(
                      tooltip: 'Im Entwurf bearbeiten',
                      icon: const Icon(Icons.edit),
                      onPressed: () => _edit(context, cut),
                    ),
                    IconButton(
                      tooltip: 'Umbenennen',
                      icon: const Icon(Icons.drive_file_rename_outline),
                      onPressed: () => _rename(context, cut),
                    ),
                    IconButton(
                      tooltip: 'Löschen',
                      icon: const Icon(Icons.delete),
                      onPressed: () => _delete(context, cut),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
