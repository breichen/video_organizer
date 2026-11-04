/// Ein getaggtes und bewertetes Intervall innerhalb eines Videos.
class Segment {
  final String id;
  final String videoPath;
  int startMs;
  int endMs;
  List<String> tags;

  /// 0 = unbewertet, 1–5 Sterne
  int rating;

  Segment({
    required this.id,
    required this.videoPath,
    required this.startMs,
    required this.endMs,
    List<String>? tags,
    this.rating = 0,
  }) : tags = tags ?? [];

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'videoPath': videoPath,
        'startMs': startMs,
        'endMs': endMs,
        'tags': tags,
        'rating': rating,
      };

  factory Segment.fromJson(Map<String, dynamic> j) => Segment(
        id: j['id'] as String,
        videoPath: j['videoPath'] as String,
        startMs: j['startMs'] as int,
        endMs: j['endMs'] as int,
        tags: List<String>.from(j['tags'] ?? const []),
        rating: (j['rating'] ?? 0) as int,
      );
}

/// Formatiert eine Dauer als m:ss.t bzw. h:mm:ss.t
String fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final t = d.inMilliseconds.remainder(1000) ~/ 100;
  return h > 0 ? '$h:$m:$s.$t' : '$m:$s.$t';
}

/// Zerlegt "strand, sonnenuntergang" in eine Tag-Liste (ohne Duplikate).
List<String> parseTags(String input) => input
    .split(RegExp(r'[,;]'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toSet()
    .toList();

/// Ergebnis der Dateinamen-Auswertung.
class ParsedName {
  final String title;
  final List<String> performers;
  const ParsedName(this.title, this.performers);
}

/// Regeln, um aus einem Dateinamen (ohne Endung) Titel und DarstellerInnen zu bestimmen.
///
/// Beispiel mit den Standardwerten:
/// "wet-angels_bella-spark_ivi-rein_1280x720"
///   → Titel "Wet Angels", DarstellerInnen "Bella Spark", "Ivi Rein"
class FilenamePattern {
  static const defaultIgnore = r'^(\d{3,4}x\d{3,4}|\d{3,4}p|\d{1,2}k|uhd|fhd|hd)$';

  /// Trennt den Dateinamen in Teile, z. B. "_".
  final String partSeparator;

  /// Zeichen, die innerhalb eines Teils Wörter trennen, z. B. "-" (jedes Zeichen einzeln).
  final String wordSeparators;

  /// Optional: trennt mehrere DarstellerInnen innerhalb eines Teils, z. B. " & ".
  final String performerSeparator;

  /// Teile ab 1; negative Werte zählen von hinten (-1 = letzter); 0 = nicht verwenden.
  final int titleFrom;
  final int titleTo;
  final int performersFrom;
  final int performersTo;

  /// Teile, die dazu passen, werden vor dem Zuordnen entfernt (z. B. Auflösung).
  final String ignoreRegex;

  /// Jedes Wort mit Großbuchstaben beginnen.
  final bool titleCase;

  const FilenamePattern({
    this.partSeparator = '_',
    this.wordSeparators = '-',
    this.performerSeparator = '',
    this.titleFrom = 1,
    this.titleTo = 1,
    this.performersFrom = 2,
    this.performersTo = -1,
    this.ignoreRegex = defaultIgnore,
    this.titleCase = true,
  });

  bool get hasTitle => titleFrom != 0 && titleTo != 0;
  bool get hasPerformers => performersFrom != 0 && performersTo != 0;

  RegExp? get _ignoreRx {
    if (ignoreRegex.trim().isEmpty) return null;
    try {
      return RegExp(ignoreRegex, caseSensitive: false);
    } catch (_) {
      return null; // ungültiges Muster: nichts ignorieren
    }
  }

  ParsedName parse(String name) {
    var parts = (partSeparator.isEmpty ? [name] : name.split(partSeparator))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final rx = _ignoreRx;
    if (rx != null) parts = parts.where((e) => !rx.hasMatch(e)).toList();

    int cl(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

    List<String> slice(int from, int to) {
      if (from == 0 || to == 0 || parts.isEmpty) return const [];
      int norm(int i) => i > 0 ? i - 1 : parts.length + i;
      final rawLo = norm(from), rawHi = norm(to);
      if (rawLo >= parts.length || rawHi < 0) return const [];
      final lo = cl(rawLo, 0, parts.length - 1);
      final hi = cl(rawHi, 0, parts.length - 1);
      if (lo > hi) return const [];
      return parts.sublist(lo, hi + 1);
    }

    String clean(String s) {
      for (final ch in wordSeparators.split('')) {
        s = s.replaceAll(ch, ' ');
      }
      s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (titleCase) {
        s = s
            .split(' ')
            .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
            .join(' ');
      }
      return s;
    }

    final title = slice(titleFrom, titleTo)
        .map(clean)
        .where((e) => e.isNotEmpty)
        .join(' - ');

    final names = <String>[];
    for (final part in slice(performersFrom, performersTo)) {
      final pieces = performerSeparator.isEmpty ? [part] : part.split(performerSeparator);
      for (final piece in pieces) {
        final n = clean(piece);
        if (n.isNotEmpty && !names.any((e) => e.toLowerCase() == n.toLowerCase())) {
          names.add(n);
        }
      }
    }
    return ParsedName(title, names);
  }

  Map<String, dynamic> toJson() => {
        'partSeparator': partSeparator,
        'wordSeparators': wordSeparators,
        'performerSeparator': performerSeparator,
        'titleFrom': titleFrom,
        'titleTo': titleTo,
        'performersFrom': performersFrom,
        'performersTo': performersTo,
        'ignoreRegex': ignoreRegex,
        'titleCase': titleCase,
      };

  factory FilenamePattern.fromJson(Map<String, dynamic> j) => FilenamePattern(
        partSeparator: (j['partSeparator'] ?? '_') as String,
        wordSeparators: (j['wordSeparators'] ?? '-') as String,
        performerSeparator: (j['performerSeparator'] ?? '') as String,
        titleFrom: (j['titleFrom'] ?? 1) as int,
        titleTo: (j['titleTo'] ?? 1) as int,
        performersFrom: (j['performersFrom'] ?? 2) as int,
        performersTo: (j['performersTo'] ?? -1) as int,
        ignoreRegex: (j['ignoreRegex'] ?? defaultIgnore) as String,
        titleCase: (j['titleCase'] ?? true) as bool,
      );
}
