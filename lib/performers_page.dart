import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'player_page.dart';
import 'store.dart';
import 'thumb_widgets.dart';
import 'clip_filter.dart';
import 'cuts_hub_page.dart';

/// Liste aller DarstellerInnen (links) und ihrer Videos (rechts) –
/// mit Umbenennen, Synonymen und Zusammenführen.
class PerformersPage extends StatefulWidget {
  final Store store;
  const PerformersPage({super.key, required this.store});

  @override
  State<PerformersPage> createState() => _PerformersPageState();
}

class _PerformersPageState extends State<PerformersPage> {
  String? _selected;
  String _filter = '';

  Store get store => widget.store;

  Future<bool> _confirm(String title, String text, {String yes = 'OK'}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _rename(String old) async {
    final c = TextEditingController(text: old);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('„$old“ umbenennen'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: c,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Neuer Name',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 8),
              const Text(
                'Die ursprüngliche Schreibweise bleibt bei den Videos gespeichert und gilt '
                'als Synonym. Unter „Synonyme“ kannst du die Umbenennung jederzeit '
                'rückgängig machen.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Umbenennen')),
        ],
      ),
    );
    final newName = c.text.trim();
    if (ok != true || newName.isEmpty || newName == old) return;

    final conflict = store.performerConflict(old, newName);
    if (conflict != null) {
      final merge = await _confirm(
        'Zusammenführen?',
        '„$newName“ gibt es schon (als „$conflict“). „$old“ wird mit „$conflict“ '
        'zusammengeführt. Das lässt sich unter „Synonyme“ wieder rückgängig machen.',
        yes: 'Zusammenführen',
      );
      if (!merge) return;
    }
    final result = await store.renamePerformer(old, newName);
    if (mounted) setState(() => _selected = result);
  }

  Future<void> _manageAliases(String name) async {
    final c = TextEditingController();
    var mergeFrom = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => ListenableBuilder(
          listenable: store,
          builder: (ctx, _) {
            final aliases = store.aliasesOf(name);
            final counts = store.performerCounts();
            final others = store.allPerformers
                .where((n) => n.toLowerCase() != name.toLowerCase())
                .toList();
            return AlertDialog(
              title: Text('Synonyme für „$name“'),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Die Namen bei den Videos bleiben unverändert gespeichert; ein Synonym zu entfernen '
                        'trennt die Personen wieder. '
                        'Synonyme werden beim Eintragen und bei der Dateinamen-Auswertung '
                        'automatisch zu „$name“. Gibst du einen Namen ein, den es schon als '
                        'eigene Person gibt, werden beide zusammengeführt.',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      if (aliases.isEmpty)
                        const Text('Noch keine Synonyme.')
                      else
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final a in aliases)
                              InputChip(
                                label: Text(a),
                                deleteButtonTooltipMessage: 'Trennen: gilt wieder als eigene Person',
                                onDeleted: () => store.removeAlias(a),
                              ),
                          ],
                        ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: c,
                        decoration: const InputDecoration(
                          labelText: 'Synonym hinzufügen (Enter)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (v) async {
                          await store.addAlias(name, v);
                          c.clear();
                        },
                      ),
                      const Divider(height: 24),
                      Text(
                        'Mit vorhandener Person zusammenführen',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownMenu<String>(
                            key: ValueKey(others.length),
                            width: 260,
                            enableFilter: true,
                            label: const Text('Person'),
                            dropdownMenuEntries: [
                              for (final n in others)
                                DropdownMenuEntry(value: n, label: '$n (${counts[n] ?? 0})'),
                            ],
                            onSelected: (v) => setS(() => mergeFrom = v ?? ''),
                          ),
                          FilledButton(
                            onPressed: mergeFrom.isEmpty
                                ? null
                                : () async {
                                    final from = mergeFrom;
                                    final ok = await _confirm(
                                      'Zusammenführen?',
                                      '„$from“ wird mit „$name“ zusammengeführt: Alle Videos von '
                                      '„$from“ gehören danach zu „$name“, und „$from“ wird als '
                                      'Synonym gemerkt. Das lässt sich unter „Synonyme“ wieder rückgängig machen.',
                                      yes: 'Zusammenführen',
                                    );
                                    if (!ok) return;
                                    await store.mergePerformers(from: from, into: name);
                                    setS(() => mergeFrom = '');
                                  },
                            child: const Text('Zusammenführen'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen')),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final everyone = store.allPerformers;
        final counts = store.performerCounts();
        final f = _filter.toLowerCase();
        final names = everyone
            .where((n) =>
                n.toLowerCase().contains(f) ||
                store.aliasesOf(n).any((a) => a.toLowerCase().contains(f)))
            .toList();
        final sel = everyone.contains(_selected) ? _selected : null;
        final vids = sel == null ? const <String>[] : store.videosWithPerformer(sel);
        final aliases = sel == null ? const <String>[] : store.aliasesOf(sel);

        return Scaffold(
          appBar: AppBar(title: Text('DarstellerInnen (${everyone.length})')),
          body: everyone.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Noch keine DarstellerInnen eingetragen.\n'
                      'Trage sie im Player unter „Video-Infos“ ein.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Row(
                  children: [
                    SizedBox(
                      width: 320,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: TextField(
                              decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                hintText: 'Name oder Synonym suchen…',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (v) => setState(() => _filter = v),
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              itemCount: names.length,
                              itemBuilder: (_, i) {
                                final n = names[i];
                                final al = store.aliasesOf(n);
                                return ListTile(
                                  dense: true,
                                  selected: n == sel,
                                  leading: const Icon(Icons.person),
                                  title: Text(n),
                                  subtitle: al.isEmpty
                                      ? null
                                      : Text(
                                          '= ${al.join(', ')}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                  trailing: Text('${counts[n] ?? 0}'),
                                  onTap: () => setState(() => _selected = n),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: sel == null
                          ? const Center(child: Text('Wähle links eine Person.'))
                          : Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              sel,
                                              style: Theme.of(context).textTheme.titleLarge,
                                            ),
                                            Text('${vids.length} Videos'),
                                            if (aliases.isNotEmpty)
                                              Text(
                                                'Auch bekannt als: ${aliases.join(', ')}',
                                                style: const TextStyle(
                                                  fontStyle: FontStyle.italic,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      Flexible(
                                        child: Wrap(
                                          alignment: WrapAlignment.end,
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            OutlinedButton.icon(
                                              onPressed: () => _rename(sel),
                                              icon: const Icon(Icons.edit),
                                              label: const Text('Umbenennen'),
                                            ),
                                            OutlinedButton.icon(
                                              onPressed: () => _manageAliases(sel),
                                              icon: const Icon(Icons.merge_type),
                                              label: const Text('Synonyme'),
                                            ),
                                            FilledButton.icon(
                                              onPressed: () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) => CutsHubPage(
                                                    store: store,
                                                    initialTab: 1,
                                                    initialFilter: ClipFilter(performer: sel),
                                                  ),
                                                ),
                                              ),
                                              icon: const Icon(Icons.shuffle),
                                              label: const Text('Zusammenschnitt'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),
                                Expanded(
                                  child: vids.isEmpty
                                      ? const Center(
                                          child: Text('Keine Videos in den aktuellen Ordnern.'),
                                        )
                                      : ListView.builder(
                                          itemCount: vids.length,
                                          itemBuilder: (_, i) {
                                            final v = vids[i];
                                            return ListTile(
                                              leading: VideoThumb(store: store, path: v, width: 96, height: 54),
                                              title: Text(store.displayName(v)),
                                              subtitle: Text(
                                                store.titleFor(v).isNotEmpty
                                                    ? '${p.basename(v)} · ${p.dirname(v)}'
                                                    : p.dirname(v),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              onTap: () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      PlayerPage(store: store, path: v),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
