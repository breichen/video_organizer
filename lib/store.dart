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
    _invalidate();
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
    _invalidate();
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
    if (dirty) _invalidate();
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
  //
  // In den Videos stehen die Namen so, wie sie eingegeben bzw. aus dem Dateinamen gelesen
  // wurden (Originalnamen). Welche Namen dieselbe Person sind, steht getrennt in
  // [performerAliases] (Schreibweise → Hauptname). So lassen sich Umbenennen und
  // Zusammenführen rückgängig machen, indem man den Eintrag dort entfernt.

  Map<String, String>? _aliasMap; // klein geschrieben: Synonym → Ziel
  Map<String, List<String>>? _aliasGroups; // Hauptname (klein) → Synonyme
  List<String>? _allPerformersCache;

  void _invalidate() {
    _aliasMap = null;
    _aliasGroups = null;
    _allPerformersCache = null;
  }

  Map<String, String> get _aliasLower => _aliasMap ??= {
        for (final e in performerAliases.entries) e.key.toLowerCase(): e.value,
      };

  /// Folgt der Kette der Synonyme bis zum Hauptnamen.
  String _follow(String name) {
    var cur = name.trim();
    final seen = <String>{};
    while (true) {
      final low = cur.toLowerCase();
      if (!seen.add(low)) return cur; // Zyklus-Schutz
      final next = _aliasLower[low];
      if (next == null) return cur;
      cur = next;
    }
  }

  Map<String, List<String>> get _groups => _aliasGroups ??= () {
        final m = <String, List<String>>{};
        for (final k in performerAliases.keys) {
          final root = _follow(k).toLowerCase();
          if (root == k.toLowerCase()) continue;
          (m[root] ??= <String>[]).add(k);
        }
        for (final l in m.values) {
          l.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        }
        return m;
      }();

  /// Löst einen Namen über die Synonyme zum Hauptnamen auf.
  String resolvePerformer(String name) => _follow(name);

  /// Die Originalnamen, wie sie beim Video gespeichert sind.
  List<String> rawPerformersFor(String path) => performers[path] ?? const <String>[];

  /// DarstellerInnen eines Videos (Synonyme aufgelöst, ohne Doppelte).
  List<String> performersFor(String path) {
    final raw = performers[path];
    if (raw == null || raw.isEmpty) return const <String>[];
    final out = <String>[];
    for (final r in raw) {
      final n = _follow(r);
      if (!out.any((e) => e.toLowerCase() == n.toLowerCase())) out.add(n);
    }
    return out;
  }

  /// Alle Personen (Synonyme aufgelöst), alphabetisch.
  List<String> get allPerformers => _allPerformersCache ??= () {
        final m = <String, String>{};
        for (final raw in performers.values) {
          for (final r in raw) {
            final n = _follow(r);
            m.putIfAbsent(n.toLowerCase(), () => n);
          }
        }
        return m.values.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      }();

  /// Trägt Namen als Originalnamen beim Video ein (Schreibweise wie bereits vorhanden).
  /// Ist dieselbe Person (auch über ein Synonym) schon eingetragen, wird nichts doppelt.
  Future<void> addPerformers(String path, List<String> names) async {
    final spell = _performerLookup();
    final cur = List<String>.from(performers[path] ?? const <String>[]);
    for (final n in names) {
      final c = spell.putIfAbsent(n.toLowerCase(), () => n);
      final target = _follow(c).toLowerCase();
      if (!cur.any((e) => _follow(e).toLowerCase() == target)) cur.add(c);
    }
    if (cur.isEmpty) return;
    performers[path] = cur;
    await changed();
  }

  /// Entfernt eine Person von einem Video (alle Originalnamen, die zu ihr gehören).
  Future<void> removePerformer(String path, String name) async {
    final cur = performers[path];
    if (cur == null) return;
    final target = name.toLowerCase();
    cur.removeWhere((r) => _follow(r).toLowerCase() == target);
    if (cur.isEmpty) performers.remove(path);
    await changed();
  }

  /// Videos (aus den aktuell eingelesenen Ordnern) mit dieser Person.
  List<String> videosWithPerformer(String name) {
    final lower = name.toLowerCase();
    return videos
        .where((v) => performersFor(v).any((n) => n.toLowerCase() == lower))
        .toList();
  }

  /// Anzahl eingelesener Videos pro Person.
  Map<String, int> performerCounts() {
    final spell = {for (final n in allPerformers) n.toLowerCase(): n};
    final m = <String, int>{for (final n in allPerformers) n: 0};
    for (final v in videos) {
      for (final n in performersFor(v)) {
        final key = spell[n.toLowerCase()] ?? n;
        m[key] = (m[key] ?? 0) + 1;
      }
    }
    return m;
  }

  // ---- Umbenennen, Zusammenführen, Synonyme (alles rückgängig machbar) ----

  /// Synonyme einer Person (alle Schreibweisen, die über Synonyme zu ihr führen).
  List<String> aliasesOf(String name) {
    if (performerAliases.isEmpty) return const <String>[];
    return _groups[_follow(name).toLowerCase()] ?? const <String>[];
  }

  bool _isKnownName(String name) {
    final low = name.trim().toLowerCase();
    if (_aliasLower.containsKey(low)) return true;
    if (performerAliases.values.any((v) => v.toLowerCase() == low)) return true;
    return allPerformers.any((e) => e.toLowerCase() == low);
  }

  /// Gibt es den neuen Namen schon für eine ANDERE Person (oder als deren Synonym)?
  /// Dann deren Hauptname, sonst null.
  String? performerConflict(String old, String newName) {
    if (!_isKnownName(newName)) return null;
    final target = _follow(newName);
    return target.toLowerCase() == _follow(old).toLowerCase() ? null : target;
  }

  /// Nur Groß-/Kleinschreibung ändern: passt die Schreibweise überall an.
  void _respell(String from, String to) {
    final low = from.toLowerCase();
    for (final path in performers.keys.toList()) {
      final next = <String>[];
      for (final r in performers[path]!) {
        final v = r.toLowerCase() == low ? to : r;
        if (!next.any((x) => x.toLowerCase() == v.toLowerCase())) next.add(v);
      }
      performers[path] = next;
    }
    for (final k in performerAliases.keys.toList()) {
      if (performerAliases[k]!.toLowerCase() == low) performerAliases[k] = to;
      if (k.toLowerCase() == low) performerAliases[to] = performerAliases.remove(k)!;
    }
    _invalidate();
  }

  /// Benennt eine Person um. Die Videos behalten ihre Originalnamen; der bisherige Name
  /// wird Synonym des neuen (rückgängig: Synonym entfernen). Existiert der neue Name schon
  /// bei einer anderen Person, werden beide zusammengeführt. Gibt den neuen Namen zurück.
  Future<String> renamePerformer(String old, String newName) async {
    final n = newName.trim();
    final root = _follow(old);
    if (n.isEmpty) return root;
    final conflict = performerConflict(root, n);
    if (conflict != null) {
      await mergePerformers(from: root, into: conflict);
      return conflict;
    }
    if (n.toLowerCase() == root.toLowerCase()) {
      _respell(root, n);
      await changed();
      return n;
    }
    // Der neue Name war evtl. schon ein Synonym derselben Person: Rollen tauschen.
    performerAliases.removeWhere((k, v) => k.toLowerCase() == n.toLowerCase());
    performerAliases[root] = n;
    _invalidate();
    await changed();
    return n;
  }

  /// Führt [from] mit [into] zusammen. Die Videos bleiben unverändert; nur die Gleichsetzung
  /// wird in [performerAliases] vermerkt (rückgängig: Synonym entfernen).
  Future<void> mergePerformers({required String from, required String into}) async {
    final a = _follow(from);
    final b = _follow(into);
    if (a.toLowerCase() == b.toLowerCase()) return;
    performerAliases[a] = b;
    _invalidate();
    await changed();
  }

  /// Fügt [alias] als Synonym von [canonical] hinzu. Ist [alias] schon eine eigene Person,
  /// werden beide zusammengeführt.
  Future<void> addAlias(String canonical, String alias) async {
    final a = alias.trim();
    final root = _follow(canonical);
    if (a.isEmpty || a.toLowerCase() == root.toLowerCase()) return;
    final other = _follow(a);
    if (other.toLowerCase() == root.toLowerCase()) return; // schon dieselbe Person
    if (_isKnownName(a)) {
      await mergePerformers(from: other, into: root);
      return;
    }
    performerAliases[a] = root;
    _invalidate();
    await changed();
  }

  /// Entfernt ein Synonym: die Schreibweise gilt wieder als eigene Person.
  Future<void> removeAlias(String alias) async {
    performerAliases.remove(alias);
    _invalidate();
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

  /// Schreibweisen aller bekannten Namen (Originalnamen in Videos, Synonyme und deren
  /// Hauptnamen): klein geschrieben → Schreibweise. Neue Eingaben übernehmen so die
  /// vorhandene Schreibweise.
  Map<String, String> _performerLookup() {
    final m = <String, String>{};
    for (final raw in performers.values) {
      for (final n in raw) {
        m.putIfAbsent(n.toLowerCase(), () => n);
      }
    }
    for (final e in performerAliases.entries) {
      m.putIfAbsent(e.key.toLowerCase(), () => e.key);
      m.putIfAbsent(e.value.toLowerCase(), () => e.value);
    }
    return m;
  }

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
