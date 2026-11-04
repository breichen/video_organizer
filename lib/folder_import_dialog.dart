import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'store.dart' show videoExtensions;

class PatternDialogResult {
  /// null = keine Dateinamen-Auswertung für diesen Ordner.
  final FilenamePattern? pattern;

  /// Nur beim Bearbeiten: bereits eingelesene Videos neu auswerten und überschreiben.
  final bool overwrite;

  /// Serie für alle Videos im Ordner ('' = keine).
  final String series;
  const PatternDialogResult(this.pattern, {this.overwrite = false, this.series = ''});
}

/// Zeigt den Dialog; null = abgebrochen.
Future<PatternDialogResult?> showPatternDialog(
  BuildContext context, {
  required String folder,
  required List<String> samples,
  FilenamePattern? initial,
  String initialSeries = '',
  required bool isNew,
}) =>
    showDialog<PatternDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PatternDialog(
        folder: folder,
        samples: samples,
        initial: initial,
        initialSeries: initialSeries,
        isNew: isNew,
      ),
    );

class _PatternDialog extends StatefulWidget {
  final String folder;
  final List<String> samples;
  final FilenamePattern? initial;
  final String initialSeries;
  final bool isNew;
  const _PatternDialog({
    required this.folder,
    required this.samples,
    required this.initial,
    required this.initialSeries,
    required this.isNew,
  });

  @override
  State<_PatternDialog> createState() => _PatternDialogState();
}

class _PatternDialogState extends State<_PatternDialog> {
  late final TextEditingController _partSep;
  late final TextEditingController _wordSep;
  late final TextEditingController _perfSep;
  late final TextEditingController _ignore;
  late final TextEditingController _example;
  late final TextEditingController _series;
  late final TextEditingController _tfC, _ttC, _pfC, _ptC;
  late int _tf, _tt, _pf, _pt;
  late bool _titleCase;
  bool _overwrite = false;

  @override
  void initState() {
    super.initState();
    final i = widget.initial ?? const FilenamePattern();
    _partSep = TextEditingController(text: i.partSeparator);
    _wordSep = TextEditingController(text: i.wordSeparators);
    _perfSep = TextEditingController(text: i.performerSeparator);
    _ignore = TextEditingController(text: i.ignoreRegex);
    _example = TextEditingController(text: 'wet-angels_bella-spark_ivi-rein_1280x720');
    _series = TextEditingController(text: widget.initialSeries);
    _tf = i.titleFrom;
    _tt = i.titleTo;
    _pf = i.performersFrom;
    _pt = i.performersTo;
    _tfC = TextEditingController(text: '$_tf');
    _ttC = TextEditingController(text: '$_tt');
    _pfC = TextEditingController(text: '$_pf');
    _ptC = TextEditingController(text: '$_pt');
    _titleCase = i.titleCase;
  }

  @override
  void dispose() {
    for (final c in [
      _partSep, _wordSep, _perfSep, _ignore, _example, _series, _tfC, _ttC, _pfC, _ptC,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  FilenamePattern get _pattern => FilenamePattern(
        partSeparator: _partSep.text,
        wordSeparators: _wordSep.text,
        performerSeparator: _perfSep.text,
        titleFrom: _tf,
        titleTo: _tt,
        performersFrom: _pf,
        performersTo: _pt,
        ignoreRegex: _ignore.text,
        titleCase: _titleCase,
      );

  String _stripExt(String name) {
    final ext = p.extension(name).toLowerCase();
    return videoExtensions.contains(ext) ? p.basenameWithoutExtension(name) : name;
  }

  Widget _text(TextEditingController c, String label, {String? hint}) => TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (_) => setState(() {}),
      );

  Widget _intField(String label, TextEditingController c, ValueChanged<int> onValue) =>
      SizedBox(
        width: 90,
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))],
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null) setState(() => onValue(n));
          },
        ),
      );

  Widget _previewRow(String name) {
    final r = _pattern.parse(name);
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('→ Titel: ${r.title.isEmpty ? '–' : r.title}'),
          Text('→ DarstellerInnen: ${r.performers.isEmpty ? '–' : r.performers.join(', ')}'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final samples = widget.samples.take(5).map((s) => p.basenameWithoutExtension(s)).toList();
    return AlertDialog(
      title: Text(widget.isNew
          ? 'Ordner importieren: Titel & DarstellerInnen aus Dateinamen'
          : 'Dateinamen-Auswertung'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.folder, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              TextField(
                controller: _series,
                decoration: const InputDecoration(
                  labelText: 'Serie (optional)',
                  helperText: 'Gilt für alle Videos in diesem Ordner.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Der Dateiname (ohne Endung) wird am Teil-Trenner in Teile zerlegt. '
                'Teile, die zum Ignorieren-Muster passen (z. B. 1280x720), fallen vorher weg. '
                'Nummern zählen ab 1, negative Zahlen von hinten (−1 = letzter Teil), '
                '0 = nicht verwenden.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _text(_partSep, 'Teil-Trenner', hint: '_')),
                  const SizedBox(width: 8),
                  Expanded(child: _text(_wordSep, 'Wort-Trenner (Zeichen)', hint: '-')),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Titel: Teil'),
                  _intField('von', _tfC, (n) => _tf = n),
                  const Text('bis'),
                  _intField('bis', _ttC, (n) => _tt = n),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('DarstellerInnen: Teil'),
                  _intField('von', _pfC, (n) => _pf = n),
                  const Text('bis'),
                  _intField('bis', _ptC, (n) => _pt = n),
                ],
              ),
              const SizedBox(height: 8),
              _text(
                _perfSep,
                'Mehrere DarstellerInnen in einem Teil getrennt durch (optional)',
                hint: 'z. B. " & " oder ","',
              ),
              const SizedBox(height: 8),
              _text(_ignore, 'Teile ignorieren, die diesem Muster entsprechen (Regex)'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Jedes Wort groß beginnen'),
                value: _titleCase,
                onChanged: (v) => setState(() => _titleCase = v),
              ),
              const Divider(),
              Text('Vorschau', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              _text(_example, 'Beispiel-Dateiname'),
              _previewRow(_stripExt(_example.text.trim())),
              if (samples.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Dateien aus dem Ordner:', style: TextStyle(fontSize: 12)),
                for (final s in samples) _previewRow(s),
              ],
              if (!widget.isNew) ...[
                const Divider(),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'Auf bereits eingelesene Videos dieses Ordners anwenden '
                    '(überschreibt deren Titel/DarstellerInnen/Serie)',
                  ),
                  value: _overwrite,
                  onChanged: (v) => setState(() => _overwrite = v ?? false),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            PatternDialogResult(null, overwrite: _overwrite, series: _series.text.trim()),
          ),
          child: Text(
            widget.isNew ? 'Ohne Dateinamen-Auswertung importieren' : 'Dateinamen-Auswertung aus',
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            PatternDialogResult(_pattern, overwrite: _overwrite, series: _series.text.trim()),
          ),
          child: Text(widget.isNew ? 'Importieren' : 'Speichern'),
        ),
      ],
    );
  }
}
