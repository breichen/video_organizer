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
