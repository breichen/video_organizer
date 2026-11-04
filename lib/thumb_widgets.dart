import 'dart:io';

import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';

/// Zeigt ein Bild, das asynchron geladen bzw. erzeugt wird (mit Platzhalter).
/// [loader] bekommt eine Funktion, die sagt, ob das Ergebnis noch gebraucht wird.
class Thumb extends StatefulWidget {
  final Future<File?> Function(bool Function() wanted) loader;
  final double width;
  final double height;
  final Widget? overlay;

  const Thumb({
    super.key,
    required this.loader,
    this.width = 112,
    this.height = 63,
    this.overlay,
  });

  @override
  State<Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<Thumb> {
  File? _file;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    widget.loader(() => mounted).then((f) {
      if (mounted) {
        setState(() {
          _file = f;
          _done = true;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: _done
            ? const Icon(Icons.movie, size: 22)
            : const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_file != null)
              Image.file(
                _file!,
                fit: BoxFit.cover,
                cacheWidth: (widget.width * 2).round(),
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => placeholder,
              )
            else
              placeholder,
            if (widget.overlay != null) widget.overlay!,
          ],
        ),
      ),
    );
  }
}

/// Thumbnail eines ganzen Videos: zufälliges Bild (einmal gewählt und gespeichert)
/// oder das vom Anwender gewählte.
class VideoThumb extends StatelessWidget {
  final Store store;
  final String path;
  final double width;
  final double height;

  const VideoThumb({
    super.key,
    required this.store,
    required this.path,
    this.width = 112,
    this.height = 63,
  });

  @override
  Widget build(BuildContext context) {
    return Thumb(
      key: ValueKey('v:$path:${store.videoThumbMs[path]}'),
      width: width,
      height: height,
      loader: (wanted) async {
        final svc = store.thumbs;
        if (svc == null) return null;
        return svc.videoFrame(
          path,
          knownMs: store.videoThumbMs[path],
          onPick: (ms) => store.pickVideoThumbQuiet(path, ms),
          wanted: wanted,
        );
      },
    );
  }
}

/// Thumbnail eines Clips: Bild aus der Mitte des Intervalls.
class ClipThumb extends StatelessWidget {
  final Store store;
  final Segment segment;
  final double width;
  final double height;
  final Widget? overlay;

  const ClipThumb({
    super.key,
    required this.store,
    required this.segment,
    this.width = 112,
    this.height = 63,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    return Thumb(
      key: ValueKey('c:${segment.id}:${segment.startMs}:${segment.endMs}'),
      width: width,
      height: height,
      overlay: overlay,
      loader: (wanted) async {
        final svc = store.thumbs;
        if (svc == null) return null;
        return svc.get(
          segment.videoPath,
          (segment.startMs + segment.endMs) ~/ 2,
          wanted: wanted,
        );
      },
    );
  }
}
