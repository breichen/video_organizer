import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'folder_import_dialog.dart';
import 'performers_page.dart';
import 'player_page.dart';
import 'store.dart';
import 'thumb_widgets.dart';
import 'cuts_hub_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final store = Store();
  await store.load();
  runApp(VideoOrganizerApp(store: store));
}

class VideoOrganizerApp extends StatelessWidget {
  final Store store;
  const VideoOrganizerApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Video-Organizer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: LibraryPage(store: store),
      );
}

class LibraryPage extends StatefulWidget {
  final Store store;
  const LibraryPage({super.key, required this.store});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _filter = '';
  String? _videoTagFilter;
  Store get store => widget.store;

  Future<void> _addFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || !mounted) return;
    final samples = await store.sampleVideos(dir);
    if (!mounted) return;
    final res = await showPatternDialog(
      context,
      folder: dir,
      samples: samples,
      isNew: true,
    );
    if (res == null) return; // abgebrochen
    await store.addFolder(dir, pattern: res.pattern, series: res.series);
  }

  Future<void> _editPattern(String folder) async {
    final samples = await store.sampleVideos(folder);
    if (!mounted) return;
    final res = await showPatternDialog(
      context,
      folder: folder,
      samples: samples,
      initial: store.patternFor(folder),
      initialSeries: store.seriesForFolder(folder),
      isNew: false,
    );
    if (res == null) return;
    await store.setFolderRules(
      folder,
      pattern: res.pattern,
      series: res.series,
      overwrite: res.overwrite,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final activeTag =
            store.allVideoTags.contains(_videoTagFilter) ? _videoTagFilter : null;
        final videos = store.videos
            .where((v) =>
                store.matchesSearch(v, _filter) &&
                (activeTag == null || store.videoTagsFor(v).contains(activeTag)))
            .toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Video-Organizer'),
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => PerformersPage(store: store)),
                ),
                icon: const Icon(Icons.people),
                label: const Text('DarstellerInnen'),
              ),
              IconButton(
                tooltip: 'Ordner neu einlesen',
                onPressed: store.scan,
                icon: const Icon(Icons.refresh),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => CutsHubPage(store: store)),
                  ),
                  icon: const Icon(Icons.movie_filter),
                  label: const Text('Clips & Zusammenschnitte'),
                ),
              ),
            ],
          ),
          body: Row(
            children: [
              SizedBox(
                width: 300,
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('Ordner'),
                      trailing: IconButton(
                        tooltip: 'Ordner hinzufügen',
                        onPressed: _addFolder,
                        icon: const Icon(Icons.create_new_folder),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final f in store.folders)
                            ListTile(
                              dense: true,
                              title: Text(f, maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: (store.patternFor(f) != null || store.seriesForFolder(f).isNotEmpty)
                                  ? Text([
                                      if (store.seriesForFolder(f).isNotEmpty)
                                        'Serie: ${store.seriesForFolder(f)}',
                                      if (store.patternFor(f) != null) 'Dateinamen-Auswertung aktiv',
                                    ].join(' · '))
                                  : null,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Serie & Dateinamen-Auswertung einstellen',
                                    icon: const Icon(Icons.tune),
                                    onPressed: () => _editPattern(f),
                                  ),
                                  IconButton(
                                    tooltip: 'Ordner entfernen',
                                    icon: const Icon(Icons.close),
                                    onPressed: () => store.removeFolder(f),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Videos suchen (Titel, Serie, Datei, DarstellerIn)…',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _filter = v),
                      ),
                    ),
                    if (store.allVideoTags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 6,
                            children: [
                              for (final t in store.allVideoTags)
                                FilterChip(
                                  label: Text(t),
                                  selected: activeTag == t,
                                  onSelected: (sel) =>
                                      setState(() => _videoTagFilter = sel ? t : null),
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (store.scanning) const LinearProgressIndicator(),
                    Expanded(
                      child: videos.isEmpty
                          ? Center(
                              child: Text(store.folders.isEmpty
                                  ? 'Füge links einen Ordner hinzu.'
                                  : 'Keine Videos gefunden.'),
                            )
                          : ListView.builder(
                              itemCount: videos.length,
                              itemBuilder: (_, i) {
                                final v = videos[i];
                                final n = store.segmentsFor(v).length;
                                return ListTile(
                                  leading: VideoThumb(store: store, path: v),
                                  title: Text(store.displayName(v)),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        store.titleFor(v).isNotEmpty
                                            ? '${p.basename(v)} · ${p.dirname(v)}'
                                            : p.dirname(v),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (store.seriesFor(v).isNotEmpty)
                                        Text(
                                          'Serie: ${store.seriesFor(v)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      if (store.performersFor(v).isNotEmpty)
                                        Text(
                                          store.performersFor(v).join(', '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontStyle: FontStyle.italic),
                                        ),
                                      if (store.videoTagsFor(v).isNotEmpty)
                                        Wrap(
                                          spacing: 4,
                                          children: [
                                            for (final t in store.videoTagsFor(v))
                                              Chip(
                                                label: Text(t),
                                                visualDensity: VisualDensity.compact,
                                              ),
                                          ],
                                        ),
                                    ],
                                  ),
                                  trailing: n > 0 ? Chip(label: Text('$n Intervalle')) : null,
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => PlayerPage(store: store, path: v),
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
