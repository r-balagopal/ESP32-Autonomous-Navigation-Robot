class Pt {
  final int x, y;
  const Pt(this.x, this.y);
  @override
  bool operator ==(Object o) => o is Pt && o.x == x && o.y == y;
  @override
  int get hashCode => x * 1000 + y;
  @override
  String toString() => '($x,$y)';
}

enum EditMode { robot, destination, obstacle }

enum ObsType { known, detected }

enum Mission {
  disconnected,
  connected,
  ready,
  pathCalculated,
  navigating,
  obstacleDetected,
  replanning,
  stopped,
  arrived,
  error,
}

/// All physical scale lives here - nothing else hard-codes it.
class MapConfig {
  int width = 12;
  int height = 12;
  double cellM = 0.25; // 1 cell = 25 cm
}
