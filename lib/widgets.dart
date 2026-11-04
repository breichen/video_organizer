import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'store.dart';

/// 1–5 Sterne; erneuter Klick auf die aktuelle Zahl setzt auf 0 zurück.
class StarRating extends StatelessWidget {
  final int rating;
  final ValueChanged<int> onChanged;
  final double size;
  const StarRating({
    super.key,
    required this.rating,
    required this.onChanged,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) => ExcludeFocus(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= 5; i++)
              InkWell(
                onTap: () => onChanged(rating == i ? 0 : i),
                child: Icon(
                  i <= rating ? Icons.star : Icons.star_border,
                  size: size,
                  color: Colors.amber,
                ),
              ),
          ],
        ),
      );
}

/// Lautstärke-Regler mit Stumm-Schalter. Der Wert wird im Store gespeichert
/// und gilt für Player und Zusammenschnitt.
class VolumeControl extends StatefulWidget {
  final Player player;
  final Store store;
  const VolumeControl({super.key, required this.player, required this.store});

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  late double _v = widget.store.volume;
  double _last = 100;

  @override
  void initState() {
    super.initState();
    if (_v > 0) _last = _v;
    widget.player.setVolume(_v);
  }

  void _set(double v) {
    setState(() => _v = v);
    widget.player.setVolume(v);
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: _v == 0 ? 'Ton an' : 'Stumm',
              icon: Icon(
                _v == 0
                    ? Icons.volume_off
                    : (_v < 50 ? Icons.volume_down : Icons.volume_up),
              ),
              onPressed: () {
                if (_v > 0) {
                  _last = _v;
                  _set(0);
                } else {
                  _set(_last);
                }
                widget.store.setVolume(_v);
              },
            ),
            SizedBox(
              width: 140,
              child: Slider(
                value: _v,
                min: 0,
                max: 100,
                onChanged: _set,
                onChangeEnd: (v) {
                  if (v > 0) _last = v;
                  widget.store.setVolume(v);
                },
              ),
            ),
          ],
        ),
      );
}
