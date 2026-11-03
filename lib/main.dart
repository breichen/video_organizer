import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'player_page.dart';
import 'store.dart';
import 'supercut_page.dart';

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
  Store get store => widget.store;

  Future<void> _addFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) await store.addFolder(dir);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final videos = store.videos
            .where((v) => p.basename(v).toLowerCase().contains(_filter.toLowerCase()))
            .toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Video-Organizer'),
            actions: [
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
                    MaterialPageRoute(builder: (_) => SupercutPage(store: store)),
                  ),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Zufalls-Zusammenschnitt'),
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
                              trailing: IconButton(
                                tooltip: 'Ordner entfernen',
                                icon: const Icon(Icons.close),
                                onPressed: () => store.removeFolder(f),
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
                          hintText: 'Videos filtern…',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _filter = v),
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
                                  leading: const Icon(Icons.movie),
                                  title: Text(p.basename(v)),
                                  subtitle: Text(p.dirname(v),
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
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
