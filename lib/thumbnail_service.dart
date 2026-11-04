import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class _Job {
  final String key;
  final wanted = <bool Function()>[];
  final done = Completer<File?>();
  _Job(this.key);
}

class _PickJob {
  final wanted = <bool Function()>[];
  final done = Completer<int?>();
}

/// Erzeugt Thumbnails (einzelne Bilder aus Videos) und legt sie als JPEG im Cache ab.
///
/// * Ist `ffmpeg` installiert (PATH oder übliche Orte), wird es benutzt: schnell und robust.
/// * Sonst wird ein Bild über einen unsichtbaren media_kit-Player aufgenommen.
///
/// Alle Aufträge laufen nacheinander. Aufträge, die niemand mehr braucht (z. B. weil die
/// Zeile weggescrollt wurde), werden übersprungen.
class ThumbnailService {
  ThumbnailService._(this.dir);

  final Directory dir;

  static Future<ThumbnailService> create() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'thumbs'));
    await d.create(recursive: true);
    return ThumbnailService._(d);
  }

  final _jobs = <String, _Job>{};
  final _picks = <String, _PickJob>{};
  final _failed = <String>{};
  final _failedPaths = <String>{};
  final _rng = Random();
  Future<void> _tail = Future.value();

  String? _ffmpeg;
  bool _ffmpegChecked = false;
  Player? _player;
  String? _openPath;

  // ------------------------------------------------------------------ öffentlich

  /// Bild des Videos bei [posMs] (aus dem Cache oder frisch erzeugt); null bei Misserfolg.
  /// [wanted] sagt, ob das Ergebnis noch gebraucht wird (sonst wird der Auftrag übersprungen).
  Future<File?> get(String videoPath, int posMs, {required bool Function() wanted}) {
    final key = _key(videoPath, posMs);
    final file = File(p.join(dir.path, '$key.jpg'));
    if (file.existsSync()) return Future.value(file);
    if (_failed.contains(key)) return Future.value(null);
    final existing = _jobs[key];
    if (existing != null) {
      existing.wanted.add(wanted);
      return existing.done.future;
    }
    final job = _Job(key)..wanted.add(wanted);
    _jobs[key] = job;
    _tail = _tail.then((_) => _run(job, videoPath, posMs, file));
    return job.done.future;
  }

  /// Bild für ein ganzes Video. Ist noch keine Position bekannt ([knownMs] == null), wird
  /// einmalig eine zufällige zwischen 10 % und 90 % der Länge gewählt und über [onPick]
  /// gemeldet (zum Speichern).
  Future<File?> videoFrame(
    String videoPath, {
    int? knownMs,
    required void Function(int ms) onPick,
    required bool Function() wanted,
  }) async {
    var pos = knownMs;
    if (pos == null) {
      pos = await _pickRandomPos(videoPath, wanted);
      if (pos == null) return null;
      onPick(pos);
    }
    return get(videoPath, pos, wanted: wanted);
  }

  // ------------------------------------------------------------------ Aufträge

  Future<void> _run(_Job job, String videoPath, int posMs, File file) async {
    try {
      if (!job.wanted.any((w) => w())) {
        job.done.complete(null);
        return;
      }
      final ok = await _generate(videoPath, posMs, file);
      if (!ok) _failed.add(job.key);
      job.done.complete(ok ? file : null);
    } catch (_) {
      _failed.add(job.key);
      if (!job.done.isCompleted) job.done.complete(null);
    } finally {
      _jobs.remove(job.key);
    }
  }

  Future<int?> _pickRandomPos(String path, bool Function() wanted) {
    if (_failedPaths.contains(path)) return Future.value(null);
    final existing = _picks[path];
    if (existing != null) {
      existing.wanted.add(wanted);
      return existing.done.future;
    }
    final job = _PickJob()..wanted.add(wanted);
    _picks[path] = job;
    _tail = _tail.then((_) async {
      try {
        if (!job.wanted.any((w) => w())) {
          job.done.complete(null);
          return;
        }
        final d = await _probeDurationMs(path);
        if (d == null || d <= 0) {
          _failedPaths.add(path);
          job.done.complete(null);
          return;
        }
        job.done.complete((d * (0.1 + 0.8 * _rng.nextDouble())).round());
      } catch (_) {
        _failedPaths.add(path);
        if (!job.done.isCompleted) job.done.complete(null);
      } finally {
        _picks.remove(path);
      }
    });
    return job.done.future;
  }

  // ------------------------------------------------------------------ Erzeugen

  Future<bool> _generate(String videoPath, int posMs, File out) async {
    final tmp = File('${out.path}.tmp.jpg');
    try {
      var ok = false;
      final ff = await _findFfmpeg();
      if (ff != null) ok = await _viaFfmpeg(ff, videoPath, posMs, tmp);
      if (!ok) ok = await _viaMediaKit(videoPath, posMs, tmp);
      if (ok) {
        await tmp.rename(out.path);
        return true;
      }
    } catch (_) {}
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    return false;
  }

  Future<String?> _findFfmpeg() async {
    if (_ffmpegChecked) return _ffmpeg;
    _ffmpegChecked = true;
    final names = Platform.isWindows
        ? ['ffmpeg.exe', 'ffmpeg']
        : [
            'ffmpeg',
            '/opt/homebrew/bin/ffmpeg',
            '/usr/local/bin/ffmpeg',
            '/usr/bin/ffmpeg',
          ];
    for (final n in names) {
      try {
        final r = await Process.run(n, ['-version']).timeout(const Duration(seconds: 5));
        if (r.exitCode == 0) {
          _ffmpeg = n;
          break;
        }
      } catch (_) {}
    }
    return _ffmpeg;
  }

  String _probeName(String ffmpeg) =>
      ffmpeg.replaceFirstMapped(RegExp(r'ffmpeg(\.exe)?$'), (m) => 'ffprobe${m[1] ?? ''}');

  Future<bool> _viaFfmpeg(String ff, String videoPath, int posMs, File tmp) async {
    try {
      final sec = (posMs / 1000).toStringAsFixed(3);
      final r = await Process.run(ff, [
        '-y', '-v', 'error',
        '-ss', sec,
        '-i', videoPath,
        '-frames:v', '1',
        '-vf', 'scale=480:-2',
        '-q:v', '4',
        tmp.path,
      ]).timeout(const Duration(seconds: 30));
      return r.exitCode == 0 && tmp.existsSync() && tmp.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  Future<int?> _probeDurationMs(String path) async {
    final ff = await _findFfmpeg();
    if (ff != null) {
      try {
        final r = await Process.run(_probeName(ff), [
          '-v', 'error',
          '-show_entries', 'format=duration',
          '-of', 'default=noprint_wrappers=1:nokey=1',
          path,
        ]).timeout(const Duration(seconds: 15));
        if (r.exitCode == 0) {
          final sec = double.tryParse((r.stdout as String).trim());
          if (sec != null && sec > 0) return (sec * 1000).round();
        }
      } catch (_) {}
    }
    return _durationViaMediaKit(path);
  }

  // ------------------------------------------------------------------ media_kit

  Player _ensurePlayer() {
    if (_player == null) {
      final pl = Player();
      VideoController(pl); // Video-Ausgabe, damit Screenshots möglich sind
      pl.setVolume(0);
      _player = pl;
    }
    return _player!;
  }

  Future<void> _openIfNeeded(Player pl, String path) async {
    if (_openPath == path) return;
    await pl.open(Media(path), play: false);
    _openPath = path;
    await pl.stream.duration
        .firstWhere((d) => d > Duration.zero)
        .timeout(const Duration(seconds: 8), onTimeout: () => pl.state.duration);
  }

  Future<int?> _durationViaMediaKit(String path) async {
    try {
      final pl = _ensurePlayer();
      await _openIfNeeded(pl, path);
      final d = pl.state.duration.inMilliseconds;
      return d > 0 ? d : null;
    } catch (_) {
      _openPath = null;
      return null;
    }
  }

  Future<bool> _viaMediaKit(String path, int posMs, File tmp) async {
    try {
      final pl = _ensurePlayer();
      await _openIfNeeded(pl, path);
      final target = Duration(milliseconds: posMs);
      await pl.seek(target);
      await pl.stream.position
          .firstWhere((q) => (q - target).abs() < const Duration(seconds: 2))
          .timeout(const Duration(seconds: 3), onTimeout: () => target);
      await Future.delayed(const Duration(milliseconds: 250));
      final bytes = await pl.screenshot(format: 'image/jpeg');
      if (bytes == null || bytes.isEmpty) return false;
      await tmp.writeAsBytes(bytes);
      return true;
    } catch (_) {
      _openPath = null;
      return false;
    }
  }

  // ------------------------------------------------------------------ Hilfen

  /// Schlüssel aus Pfad, Dateigröße, Änderungsdatum und Position: ändert sich die Datei,
  /// wird automatisch ein neues Bild erzeugt.
  String _key(String path, int posMs) {
    var size = -1, mod = 0;
    try {
      final st = File(path).statSync();
      size = st.size;
      mod = st.modified.millisecondsSinceEpoch;
    } catch (_) {}
    return _hash('$path|$size|$mod|$posMs');
  }

  /// FNV-1a (64 Bit), als Hex.
  String _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h *= 0x100000001b3;
    }
    return (h & 0x7FFFFFFFFFFFFFFF).toRadixString(16);
  }
}
