import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'store.dart';

/// Filter für Clips (Intervalle). Wird von der Clip-Übersicht und vom
/// Zufalls-Zusammenschnitt gemeinsam benutzt. Leere Texte bedeuten "alle".
class ClipFilter {
  String tag;
  String folder;
  String videoTag;
  String performer;
  int minRating;

  ClipFilter({
    this.tag = '',
    this.folder = '',
    this.videoTag = '',
    this.performer = '',
    this.minRating = 0,
  });

  bool matches(Store store, Segment s) {
    if (tag.isNotEmpty && !s.tags.contains(tag)) return false;
    if (s.rating < minRating) return false;
    if (folder.isNotEmpty && !p.isWithin(folder, s.videoPath)) return false;
    if (videoTag.isNotEmpty && !store.videoTagsFor(s.videoPath).contains(videoTag)) {
      return false;
    }
    if (performer.isNotEmpty) {
      final low = performer.toLowerCase();
      if (!store.performersFor(s.videoPath).any((n) => n.toLowerCase() == low)) return false;
    }
    return true;
  }

  List<Segment> apply(Store store) =>
      store.segments.where((s) => matches(store, s)).toList();

  /// Kurzbeschreibung, z. B. für gespeicherte Zusammenschnitte.
  String describe() {
    final parts = <String>[
      if (tag.isNotEmpty) 'Tag: $tag',
      if (minRating > 0) 'ab $minRating ★',
      if (folder.isNotEmpty) 'Ordner: ${p.basename(folder)}',
      if (videoTag.isNotEmpty) 'Video-Tag: $videoTag',
      if (performer.isNotEmpty) 'DarstellerIn: $performer',
    ];
    return parts.isEmpty ? 'Alle Clips' : parts.join(' · ');
  }
}

/// Auswahl der Filter. [extra] hängt weitere Elemente an (z. B. Sortierung).
class ClipFilterBar extends StatelessWidget {
  final Store store;
  final ClipFilter filter;
  final VoidCallback onChanged;
  final List<Widget> extra;

  const ClipFilterBar({
    super.key,
    required this.store,
    required this.filter,
    required this.onChanged,
    this.extra = const [],
  });

  @override
  Widget build(BuildContext context) {
    final videoTags = store.allVideoTags;
    final people = store.allPerformers;
    final tags = store.allTags;
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Die Keys sorgen dafür, dass die Anzeige stimmt, wenn der Filter in einem
        // anderen Tab geändert wurde.
        DropdownMenu<String>(
          key: ValueKey('folder:${filter.folder}'),
          width: 260,
          label: const Text('Ordner'),
          initialSelection: filter.folder,
          dropdownMenuEntries: [
            const DropdownMenuEntry(value: '', label: 'Alle Ordner'),
            for (final f in store.folders) DropdownMenuEntry(value: f, label: f),
          ],
          onSelected: (v) {
            filter.folder = v ?? '';
            onChanged();
          },
        ),
        if (videoTags.isNotEmpty)
          DropdownMenu<String>(
            key: ValueKey('vtag:${filter.videoTag}'),
            width: 200,
            label: const Text('Video-Tag'),
            initialSelection: filter.videoTag,
            dropdownMenuEntries: [
              const DropdownMenuEntry(value: '', label: 'Alle Videos'),
              for (final t in videoTags) DropdownMenuEntry(value: t, label: t),
            ],
            onSelected: (v) {
              filter.videoTag = v ?? '';
              onChanged();
            },
          ),
        if (people.isNotEmpty)
          DropdownMenu<String>(
            key: ValueKey('perf:${filter.performer}'),
            width: 240,
            enableFilter: true,
            label: const Text('DarstellerIn'),
            initialSelection: filter.performer,
            dropdownMenuEntries: [
              const DropdownMenuEntry(value: '', label: 'Alle DarstellerInnen'),
              for (final n in people) DropdownMenuEntry(value: n, label: n),
            ],
            onSelected: (v) {
              filter.performer = v ?? '';
              onChanged();
            },
          ),
        DropdownMenu<String>(
          key: ValueKey('tag:${filter.tag}'),
          width: 220,
          enableFilter: true,
          label: const Text('Szenen-Tag'),
          initialSelection: filter.tag,
          dropdownMenuEntries: [
            const DropdownMenuEntry(value: '', label: 'Alle Tags'),
            for (final t in tags) DropdownMenuEntry(value: t, label: t),
          ],
          onSelected: (v) {
            filter.tag = v ?? '';
            onChanged();
          },
        ),
        SizedBox(
          width: 300,
          child: Row(
            children: [
              Text(filter.minRating == 0 ? 'Alle Bewertungen' : 'Mind. ${filter.minRating} ★'),
              Expanded(
                child: Slider(
                  value: filter.minRating.toDouble(),
                  min: 0,
                  max: 5,
                  divisions: 5,
                  onChanged: (v) {
                    filter.minRating = v.round();
                    onChanged();
                  },
                ),
              ),
            ],
          ),
        ),
        ...extra,
      ],
    );
  }
}
