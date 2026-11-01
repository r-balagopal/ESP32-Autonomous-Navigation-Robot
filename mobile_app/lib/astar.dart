import 'dart:math';
import 'models.dart';

const double _diag = 1.4142135623730951; // sqrt(2)

/// 8 directions: 4 orthogonal (cost 1) + 4 diagonal (cost sqrt(2)).
const _dirs = [
  Pt(1, 0), Pt(-1, 0), Pt(0, 1), Pt(0, -1), // orthogonal
  Pt(1, 1), Pt(1, -1), Pt(-1, 1), Pt(-1, -1), // diagonal
];

/// 8-connected A* with diagonal move cost sqrt(2). Returns the path
/// including start and goal, or null if none exists.
List<Pt>? aStar(Pt s, Pt g, Set<Pt> blocked, int w, int h) {
  // Octile distance: admissible heuristic for this cost model.
  double hf(Pt a) {
    final dx = (a.x - g.x).abs(), dy = (a.y - g.y).abs();
    final mn = min(dx, dy), mx = max(dx, dy);
    return mx - mn + _diag * mn;
  }

  final gs = <Pt, double>{s: 0};
  final from = <Pt, Pt>{};
  final open = <Pt>{s};
  final closed = <Pt>{};
  while (open.isNotEmpty) {
    final c = open.reduce((a, b) => gs[a]! + hf(a) <= gs[b]! + hf(b) ? a : b);
    if (c == g) {
      final p = <Pt>[c];
      while (from.containsKey(p.first)) {
        p.insert(0, from[p.first]!);
      }
      return p;
    }
    open.remove(c);
    closed.add(c);
    for (final d in _dirs) {
      final n = Pt(c.x + d.x, c.y + d.y);
      if (n.x < 0 || n.y < 0 || n.x >= w || n.y >= h) continue;
      if (blocked.contains(n) || closed.contains(n)) continue;
      final diagonal = d.x != 0 && d.y != 0;
      if (diagonal) {
        // Don't let the robot cut a corner between two blocked cells -
        // it physically can't fit through that gap.
        final side1 = Pt(c.x + d.x, c.y);
        final side2 = Pt(c.x, c.y + d.y);
        if (blocked.contains(side1) && blocked.contains(side2)) continue;
      }
      final t = gs[c]! + (diagonal ? _diag : 1);
      if (t < (gs[n] ?? double.infinity)) {
        gs[n] = t;
        from[n] = c;
        open.add(n);
      }
    }
  }
  return null;
}