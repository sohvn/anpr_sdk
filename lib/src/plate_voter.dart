/// Stabilises noisy per-frame OCR by confidence-weighted voting.
class _Read {
  final String text;
  final double confidence;
  final DateTime time;

  const _Read(this.text, this.confidence, this.time);
}

class PlateVoter {
  final Duration window;
  final int maxReads;

  PlateVoter({required this.window, required this.maxReads});

  final List<_Read> _reads = [];

  void add(String text, double confidence, DateTime time) {
    _reads.add(_Read(text, confidence, time));
    _reads.removeWhere((r) => time.difference(r.time) > window);
    while (_reads.length > maxReads) {
      _reads.removeAt(0);
    }
  }

  String? get best {
    if (_reads.isEmpty) return null;
    final scores = <String, double>{};
    for (final r in _reads) {
      scores[r.text] = (scores[r.text] ?? 0) + r.confidence;
    }
    String? bestText;
    double bestScore = -1;
    scores.forEach((t, s) {
      if (s > bestScore) {
        bestScore = s;
        bestText = t;
      }
    });
    return bestText;
  }

  /// How many reads in the current window equal [text].
  int countOf(String text) => _reads.where((r) => r.text == text).length;

  void clear() => _reads.clear();
}
