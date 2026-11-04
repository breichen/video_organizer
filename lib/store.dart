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

/// Hält Ordner, gefundene Videos, Intervalle und Video-Tags; speichert alles als JSON.
class Store extends ChangeNotifier {
  List<String> folders = [];
  List<Segment> segments = [];
  List<String> videos = [];

  /// Tags für ganze Videos (eigener Tag-Pool, getrennt von den Szenen-Tags).
  Map<String, List<String>> videoTags = {};

  /// Optionale Titel für Videos (Pfad → Titel).
  Map<String, String> videoTitles = {};

  /// Optionale Serie pro Video (Pfad → Serie).
  Map<String, String> videoSeries = {};

  /// Serie pro Ordner: gilt für alle Videos darin (Ordner → Serie).
  Map<String, String> folderSeries = {};

  /// DarstellerInnen pro Video (Pfad → Namen).
  Map<String, List<String>> performers = {};

  /// Pro Ordner: Regeln, um Titel/DarstellerInnen aus Dateinamen zu bestimmen.
  Map<String, FilenamePattern> folderPatterns = {};

  /// Videos, bei denen die Dateinamen-Auswertung schon einmal automatisch lief
  /// (damit manuelle Änderungen später nicht überschrieben werden).
  Set<String> autoParsed = {};

  /// Synonyme: Schreibweise → Hauptname (z. B. "Bella S." → "Bella Spark").
  Map<String, String> performerAliases = {};

  /// Lautstärke 0–100
  double volume = 100;

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
        videoTags = {
          for (final e in (j['videoTags'] as Map? ?? const {}).entries)
            e.key as String: List<String>.from(e.value as List),
        };
        volume = ((j['volume'] ?? 100) as num).toDouble();
        videoTitles = {
          for (final e in (j['videoTitles'] as Map? ?? const {}).entries)
            e.key as String: e.value as String,
        };
        folderPatterns = {
          for (final e in (j['folderPatterns'] as Map? ?? const {}).entries)
            e.key as String:
                FilenamePattern.fromJson(Map<String, dynamic>.from(e.value as Map)),
        };
        autoParsed = Set<String>.from(j['autoParsed'] ?? const <String>[]);
        videoSeries = {
          for (final e in (j['videoSeries'] as Map? ?? const {}).entries)
            e.key as String: e.value as String,
        };
        folderSeries = {
          for (final e in (j['folderSeries'] as Map? ?? const {}).entries)
            e.key as String: e.value as String,
        };
        performerAliases = {
          for (final e in (j['performerAliases'] as Map? ?? const {}).entries)
            e.key as String: e.value as String,
        };
        performers = {
          for (final e in (j['performers'] as Map? ?? const {}).entries)
            e.key as String: List<String>.from(e.value as List),
        };
      } catch (_) {
        // Beschädigte Datei: mit leerem Zustand starten.
      }
    }
    notifyListeners();
    unawaited(scan()); // läuft im Hintergrund
  }

  /// Speichert, ohne Listener zu benachrichtigen.
  Future<void> save() async {
    await _file?.writeAsString(jsonEncode({
      'folders': folders,
      'segments': [for (final s in segments) s.toJson()],
      'videoTags': videoTags,
      'videoTitles': videoTitles,
      'performers': performers,
      'folderPatterns': {
        for (final e in folderPatterns.entries) e.key: e.value.toJson(),
      },
      'autoParsed': autoParsed.toList(),
      'videoSeries': videoSeries,
      'folderSeries': folderSeries,
      'performerAliases': performerAliases,
      'volume': volume,
    }));
  }

  /// Speichert und benachrichtigt nach Änderungen.
  Future<void> changed() async {
    await save();
    notifyListeners();
  }

  Future<void> setVolume(double v) async {
    volume = v;
    await save();
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
    final dirty = _autoApplyPatterns();
    notifyListeners();
    if (dirty) await save();
  }

  Future<void> addFolder(String path,
      {FilenamePattern? pattern, String series = ''}) async {
    if (folders.contains(path)) return;
    folders.add(path);
    if (pattern != null) folderPatterns[path] = pattern;
    if (series.trim().isNotEmpty) folderSeries[path] = _canonicalSeries(series.trim());
    await save();
    await scan();
  }

  Future<void> removeFolder(String path) async {
    folders.remove(path);
    folderPatterns.remove(path);
    folderSeries.remove(path);
    await save();
    await scan();
  }

  // ---- Szenen (Intervalle) ----

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

  /// Alle Szenen-Tags.
  List<String> get allTags => segments.expand((s) => s.tags).toSet().toList()..sort();

  // ---- Video-Tags ----

  List<String> videoTagsFor(String path) => videoTags[path] ?? const <String>[];

  Future<void> addVideoTags(String path, List<String> tags) async {
    final cur = List<String>.from(videoTags[path] ?? const <String>[]);
    for (final t in tags) {
      if (!cur.contains(t)) cur.add(t);
    }
    if (cur.isEmpty) return;
    videoTags[path] = cur;
    await changed();
  }

  Future<void> removeVideoTag(String path, String tag) async {
    final cur = videoTags[path];
    if (cur == null) return;
    cur.remove(tag);
    if (cur.isEmpty) videoTags.remove(path);
    await changed();
  }

  /// Alle Video-Tags.
  List<String> get allVideoTags =>
      videoTags.values.expand((e) => e).toSet().toList()..sort();

  // ---- Titel ----

  String titleFor(String path) => videoTitles[path] ?? '';

  /// Titel, falls vorhanden, sonst der Dateiname.
  String displayName(String path) {
    final t = titleFor(path).trim();
    return t.isNotEmpty ? t : p.basename(path);
  }

  /// Setzt den Titel nur im Speicher (z. B. beim Tippen); danach save()/changed() aufrufen.
  void setTitleQuiet(String path, String title) {
    final t = title.trim();
    if (t.isEmpty) {
      videoTitles.remove(path);
    } else {
      videoTitles[path] = t;
    }
  }

  // ---- DarstellerInnen ----

  List<String> performersFor(String path) => performers[path] ?? const <String>[];

  /// Alle DarstellerInnen, alphabetisch.
  List<String> get allPerformers => performers.values.expand((e) => e).toSet().toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  /// Gleiche Namen (ohne Beachtung der Groß-/Kleinschreibung) übernehmen die vorhandene Schreibweise.
  String _canonicalPerformer(String name) {
    final lower = name.toLowerCase();
    for (final existing in allPerformers) {
      if (existing.toLowerCase() == lower) return existing;
    }
    return name;
  }

  Future<void> addPerformers(String path, List<String> names) async {
    final cur = List<String>.from(performers[path] ?? const <String>[]);
    for (final n in names) {
      final c = resolvePerformer(n);
      if (!cur.any((e) => e.toLowerCase() == c.toLowerCase())) cur.add(c);
    }
    if (cur.isEmpty) return;
    performers[path] = cur;
    await changed();
  }

  Future<void> removePerformer(String path, String name) async {
    final cur = performers[path];
    if (cur == null) return;
    cur.remove(name);
    if (cur.isEmpty) performers.remove(path);
    await changed();
  }

  /// Videos (aus den aktuell eingelesenen Ordnern) mit dieser Person.
  List<String> videosWithPerformer(String name) =>
      videos.where((v) => performersFor(v).contains(name)).toList();

  /// Anzahl eingelesener Videos pro Person.
  Map<String, int> performerCounts() {
    final m = <String, int>{for (final n in allPerformers) n: 0};
    for (final v in videos) {
      for (final n in performersFor(v)) {
        m[n] = (m[n] ?? 0) + 1;
      }
    }
    return m;
  }

  // ---- Umbenennen, Zusammenführen, Synonyme ----

  /// Löst einen eingegebenen Namen auf: Synonym → Hauptname, sonst vorhandene Schreibweise.
  String resolvePerformer(String name) {
    final n = name.trim();
    final lower = n.toLowerCase();
    for (final e in performerAliases.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    for (final existing in allPerformers) {
      if (existing.toLowerCase() == lower) return existing;
    }
    return n;
  }

  /// Synonyme einer Person.
  List<String> aliasesOf(String name) {
    if (performerAliases.isEmpty) return const <String>[];
    final lower = name.toLowerCase();
    return [
      for (final e in performerAliases.entries)
        if (e.value.toLowerCase() == lower) e.key,
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  bool _isKnownName(String name) {
    final lower = name.trim().toLowerCase();
    return performerAliases.keys.any((k) => k.toLowerCase() == lower) ||
        allPerformers.any((e) => e.toLowerCase() == lower);
  }

  /// Gibt es den neuen Namen schon für eine ANDERE Person (oder als deren Synonym)?
  /// Dann deren Hauptname, sonst null.
  String? performerConflict(String old, String newName) {
    if (!_isKnownName(newName)) return null;
    final target = resolvePerformer(newName);
    return target.toLowerCase() == old.toLowerCase() ? null : target;
  }

  void _replacePerformer(String from, String to) {
    final lower = from.toLowerCase();
    for (final path in performers.keys.toList()) {
      final cur = performers[path]!;
      if (!cur.any((e) => e.toLowerCase() == lower)) continue;
      final next = <String>[];
      for (final e in cur) {
        final v = e.toLowerCase() == lower ? to : e;
        if (!next.any((x) => x.toLowerCase() == v.toLowerCase())) next.add(v);
      }
      performers[path] = next;
    }
  }

  /// Benennt eine Person in allen Videos um. Existiert der neue Name schon, wird
  /// zusammengeführt. Gibt den resultierenden Namen zurück.
  Future<String> renamePerformer(String old, String newName,
      {bool keepOldAsAlias = true}) async {
    final n = newName.trim();
    if (n.isEmpty) return old;
    final conflict = performerConflict(old, n);
    if (conflict != null) {
      await mergePerformers(from: old, into: conflict);
      return conflict;
    }
    final caseOnly = n.toLowerCase() == old.toLowerCase();
    _replacePerformer(old, n);
    for (final k in performerAliases.keys.toList()) {
      if (performerAliases[k]!.toLowerCase() == old.toLowerCase()) performerAliases[k] = n;
    }
    performerAliases.removeWhere((k, v) => k.toLowerCase() == n.toLowerCase());
    if (keepOldAsAlias && !caseOnly) performerAliases[old] = n;
    await changed();
    return n;
  }

  /// Führt [from] in [into] zusammen: alle Videos von [from] gehören danach zu [into],
  /// und [from] wird als Synonym von [into] gemerkt.
  Future<void> mergePerformers({required String from, required String into}) async {
    if (from.toLowerCase() == into.toLowerCase()) return;
    _replacePerformer(from, into);
    for (final k in performerAliases.keys.toList()) {
      if (performerAliases[k]!.toLowerCase() == from.toLowerCase()) performerAliases[k] = into;
    }
    performerAliases.removeWhere(
      (k, v) =>
          k.toLowerCase() == into.toLowerCase() || k.toLowerCase() == from.toLowerCase(),
    );
    performerAliases[from] = into;
    await changed();
  }

  /// Fügt [alias] als Synonym von [canonical] hinzu. Gibt es [alias] schon als eigene
  /// Person, werden beide zusammengeführt.
  Future<void> addAlias(String canonical, String alias) async {
    final a = alias.trim();
    if (a.isEmpty || a.toLowerCase() == canonical.toLowerCase()) return;
    final existing = allPerformers.where((e) => e.toLowerCase() == a.toLowerCase());
    if (existing.isNotEmpty) {
      await mergePerformers(from: existing.first, into: canonical);
      return;
    }
    performerAliases.removeWhere((k, v) => k.toLowerCase() == a.toLowerCase());
    performerAliases[a] = canonical;
    await changed();
  }

  Future<void> removeAlias(String alias) async {
    performerAliases.remove(alias);
    await changed();
  }

  // ---- Serie ----

  String seriesFor(String path) => videoSeries[path] ?? '';

  String seriesForFolder(String folder) => folderSeries[folder] ?? '';

  /// Alle Serien, alphabetisch.
  List<String> get allSeries => videoSeries.values.toSet().toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  /// Setzt die Serie nur im Speicher (z. B. beim Tippen); danach commitSeries() aufrufen.
  void setSeriesQuiet(String path, String series) {
    final s = series.trim();
    if (s.isEmpty) {
      videoSeries.remove(path);
    } else {
      videoSeries[path] = s;
    }
  }

  /// Übernimmt eine vorhandene Schreibweise (ohne Beachtung der Groß-/Kleinschreibung)
  /// und speichert.
  Future<void> commitSeries(String path) async {
    final cur = seriesFor(path);
    if (cur.isNotEmpty) videoSeries[path] = _canonicalSeries(cur, exceptPath: path);
    await changed();
  }

  String _canonicalSeries(String s, {String? exceptPath}) {
    final lower = s.toLowerCase();
    for (final e in videoSeries.entries) {
      if (e.key != exceptPath && e.value.toLowerCase() == lower) return e.value;
    }
    for (final v in folderSeries.values) {
      if (v.toLowerCase() == lower) return v;
    }
    return s;
  }

  // ---- Ordner-Regeln (Serie, Dateinamen-Auswertung) ----

  FilenamePattern? patternFor(String folder) => folderPatterns[folder];

  /// Ein paar Beispieldateien aus einem Ordner (für die Vorschau im Dialog).
  Future<List<String>> sampleVideos(String folder, {int max = 6}) async {
    final out = <String>[];
    try {
      await for (final e in Directory(folder).list(recursive: true, followLinks: false)) {
        if (e is File && videoExtensions.contains(p.extension(e.path).toLowerCase())) {
          out.add(e.path);
          if (out.length >= max) break;
        }
      }
    } catch (_) {}
    return out;
  }

  /// Setzt/ändert/entfernt die Regeln eines Ordners (Serie und Dateinamen-Auswertung).
  /// Die Serie wird allen Videos des Ordners gegeben, die noch keine haben. Mit [overwrite]
  /// werden bereits eingelesene Videos neu ausgewertet und deren Serie, Titel und
  /// DarstellerInnen überschrieben.
  Future<void> setFolderRules(
    String folder, {
    FilenamePattern? pattern,
    String series = '',
    bool overwrite = false,
  }) async {
    final s = series.trim().isEmpty ? '' : _canonicalSeries(series.trim());
    if (pattern == null) {
      folderPatterns.remove(folder);
    } else {
      folderPatterns[folder] = pattern;
    }
    if (s.isEmpty) {
      folderSeries.remove(folder);
    } else {
      folderSeries[folder] = s;
    }
    final canon = _performerLookup();
    for (final v in videos) {
      if (pattern != null && overwrite && _innermost(folderPatterns.keys, v) == folder) {
        _applyToVideo(v, pattern, overwrite: true, canon: canon);
        autoParsed.add(v);
      }
      if (s.isNotEmpty &&
          _innermost(folderSeries.keys, v) == folder &&
          (overwrite || seriesFor(v).isEmpty)) {
        videoSeries[v] = s;
      }
    }
    _autoApplyPatterns();
    await changed();
  }

  /// Der innerste der Ordner [keys], in dem das Video liegt (oder null).
  String? _innermost(Iterable<String> keys, String videoPath) {
    String? best;
    for (final f in keys) {
      if (p.isWithin(f, videoPath) && (best == null || f.length > best.length)) best = f;
    }
    return best;
  }

  Map<String, String> _performerLookup() => {
        for (final n in allPerformers) n.toLowerCase(): n,
        for (final e in performerAliases.entries) e.key.toLowerCase(): e.value,
      };

  void _applyToVideo(String v, FilenamePattern pat,
      {required bool overwrite, required Map<String, String> canon}) {
    final r = pat.parse(p.basenameWithoutExtension(v));
    if (pat.hasTitle && r.title.isNotEmpty && (overwrite || titleFor(v).isEmpty)) {
      videoTitles[v] = r.title;
    }
    if (pat.hasPerformers &&
        r.performers.isNotEmpty &&
        (overwrite || performersFor(v).isEmpty)) {
      final cur = <String>[];
      for (final n in r.performers) {
        final c = canon.putIfAbsent(n.toLowerCase(), () => n);
        if (!cur.any((e) => e.toLowerCase() == c.toLowerCase())) cur.add(c);
      }
      performers[v] = cur;
    }
  }

  /// Wertet neue Videos (die noch nie ausgewertet wurden) in Ordnern mit Regeln aus:
  /// Serie des Ordners und Dateinamen-Auswertung. Füllt nur leere Felder.
  /// Gibt true zurück, wenn sich etwas geändert hat.
  bool _autoApplyPatterns() {
    if (folderPatterns.isEmpty && folderSeries.isEmpty) return false;
    final canon = _performerLookup();
    var dirty = false;
    for (final v in videos) {
      if (autoParsed.contains(v)) continue;
      final pf = _innermost(folderPatterns.keys, v);
      final sf = _innermost(folderSeries.keys, v);
      if (pf == null && sf == null) continue;
      if (pf != null) _applyToVideo(v, folderPatterns[pf]!, overwrite: false, canon: canon);
      if (sf != null && seriesFor(v).isEmpty) videoSeries[v] = folderSeries[sf]!;
      autoParsed.add(v);
      dirty = true;
    }
    return dirty;
  }

  /// Suche in Dateiname, Titel und DarstellerInnen.
  bool matchesSearch(String path, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return p.basename(path).toLowerCase().contains(q) ||
        titleFor(path).toLowerCase().contains(q) ||
        seriesFor(path).toLowerCase().contains(q) ||
        performersFor(path).any((n) =>
            n.toLowerCase().contains(q) ||
            aliasesOf(n).any((a) => a.toLowerCase().contains(q)));
  }
}
