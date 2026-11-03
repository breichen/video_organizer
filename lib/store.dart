import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

const videoExtensions = {
  '.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.wmv', '.flv', '.mpg', '.mpeg',
};

/// Hält Ordner, gefundene Videos und Intervalle; speichert alles als JSON.
class Store extends ChangeNotifier {
  List<String> folders = [];
  List<Segment> segments = [];
  List<String> videos = [];
  bool scanning = false;

  File? _file;
  int _scanId = 0;

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    _file = File(p.join(dir.path, 'video_organizer.json'));
    if (await _file!.exists()) {
      try {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        folders = List<String>.from(j['folders'] ?? const []);
        segments = [
          for (final e in (j['segments'] as List? ?? const []))
            Segment.fromJson(e as Map<String, dynamic>),
        ];
      } catch (_) {
        // Beschädigte Datei: mit leerem Zustand starten.
      }
    }
    notifyListeners();
    unawaited(scan()); // läuft im Hintergrund
  }

  Future<void> _save() async {
    await _file?.writeAsString(jsonEncode({
      'folders': folders,
      'segments': [for (final s in segments) s.toJson()],
    }));
  }

  /// Speichert und benachrichtigt nach Änderungen an einem Segment.
  Future<void> changed() async {
    await _save();
    notifyListeners();
  }

  Future<void> scan() async {
    final id = ++_scanId;
    scanning = true;
    notifyListeners();
    final found = <String>{};
    for (final f in List<String>.from(folders)) {
      try {
        await for (final e in Directory(f).list(recursive: true, followLinks: false)) {
          if (e is File && videoExtensions.contains(p.extension(e.path).toLowerCase())) {
            found.add(e.path);
          }
        }
      } catch (_) {
        // Ordner nicht lesbar – überspringen.
      }
    }
    if (id != _scanId) return; // neuerer Scan läuft bereits
    videos = found.toList()
      ..sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    scanning = false;
    notifyListeners();
  }

  Future<void> addFolder(String path) async {
    if (folders.contains(path)) return;
    folders.add(path);
    await _save();
    await scan();
  }

  Future<void> removeFolder(String path) async {
    folders.remove(path);
    await _save();
    await scan();
  }

  List<Segment> segmentsFor(String videoPath) =>
      segments.where((s) => s.videoPath == videoPath).toList()
        ..sort((a, b) => a.startMs.compareTo(b.startMs));

  Future<void> addSegment(Segment s) async {
    segments.add(s);
    await changed();
  }

  Future<void> deleteSegment(Segment s) async {
    segments.remove(s);
    await changed();
  }

  List<String> get allTags =>
      segments.expand((s) => s.tags).toSet().toList()..sort();
}
