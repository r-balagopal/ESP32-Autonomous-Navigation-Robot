import 'dart:async';
import 'package:flutter/material.dart';
import 'astar.dart';
import 'link.dart';
import 'models.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();
final ctrl = Controller(ClassicLink());

class Controller extends ChangeNotifier {
  Controller(this.link) {
    link.lines.listen(_onLine);
    link.connection.listen((connected) {
      _stopSim();
      _idle();
      if (connected) _sendConfig();
      notifyListeners();
    });
  }

  final RobotLink link;
  final MapConfig cfg = MapConfig();
  EditMode mode = EditMode.robot;
  Pt? robot, dest;
  final obs = <Pt, ObsType>{};
  List<Pt> path = [];
  int heading = 90; // 0=up, 90=right, 180=down, 270=left
  Mission state = Mission.disconnected;
  Timer? _sim;

  bool get busy =>
      state == Mission.navigating ||
      state == Mission.replanning ||
      state == Mission.obstacleDetected;

  void _msg(String s) => messengerKey.currentState
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(s)));

  void _stopSim() {
    _sim?.cancel();
    _sim = null;
  }

  void _idle() {
    if (path.length > 1) {
      state = Mission.pathCalculated;
    } else if (!link.isConnected) {
      state = Mission.disconnected;
    } else {
      state = (robot != null && dest != null) ? Mission.ready : Mission.connected;
    }
  }

  void setMode(EditMode m) {
    mode = m;
    notifyListeners();
  }

  void tap(Pt p, {bool drag = false}) {
    if (busy) return _msg('Stop the mission to edit the map');
    if (mode == EditMode.robot) {
      if (obs.containsKey(p)) return _msg('Robot cannot be on an obstacle');
      if (p == dest) return _msg('Robot and destination must differ');
      robot = p;
    } else if (mode == EditMode.destination) {
      if (obs.containsKey(p)) return _msg('Destination cannot be on an obstacle');
      if (p == robot) return _msg('Robot and destination must differ');
      dest = p;
    } else {
      if (p == robot || p == dest) return _msg('Cell is occupied');
      if (obs.containsKey(p)) {
        if (drag) return;
        obs.remove(p);
      } else {
        obs[p] = ObsType.known;
      }
    }
    path = [];
    state = Mission.ready;
    _idle();
    notifyListeners();
  }

  bool calc() {
    if (robot == null || dest == null) {
      _msg('Set robot and destination first');
      return false;
    }
    final p = aStar(robot!, dest!, obs.keys.toSet(), cfg.width, cfg.height);
    if (p == null) {
      path = [];
      _idle();
      _msg('No obstacle-free route');
      notifyListeners();
      return false;
    }
    path = p;
    if (!busy) _idle();
    notifyListeners();
    return true;
  }

  /// CONFIG,width,height,cellCm — tells the robot the grid it should assume.
  void _sendConfig() {
    if (!link.isConnected) return;
    link.send('CONFIG,${cfg.width},${cfg.height},${(cfg.cellM * 100).round()}');
  }

  void start() {
    if (busy || !calc()) return;
    state = Mission.navigating;
    if (link.isConnected) {
      _sendConfig();
      link
        ..send('STARTPOS,${robot!.x},${robot!.y}')
        ..send('CLEAROBS');
      for (final o in obs.keys) {
        link.send('OBS,${o.x},${o.y}');
      }
      link
        ..send('DEST,${dest!.x},${dest!.y}')
        ..send('START');
    } else {
      _simulate(); // no robot connected: run the simulator
    }
    notifyListeners();
  }

  void _simulate() {
    _sim = Timer.periodic(const Duration(milliseconds: 400), (t) {
      if (path.length < 2) {
        t.cancel();
        state = Mission.arrived;
        notifyListeners();
        return;
      }
      final a = path[0], b = path[1];
      heading = b.x > a.x ? 90 : b.x < a.x ? 270 : b.y > a.y ? 0 : 180;
      robot = b;
      path = path.sublist(1);
      if (path.length < 2) {
        t.cancel();
        state = Mission.arrived;
      }
      notifyListeners();
    });
  }

  void stop() {
    link.send('STOP');
    _stopSim();
    state = Mission.stopped;
    notifyListeners();
  }

  void reset({bool sendReset = true}) {
    if (sendReset) link.send('RESET');
    _stopSim();
    obs.clear();
    robot = null;
    dest = null;
    path = [];
    _idle();
    notifyListeners();
  }

  void resize(int w, int h) {
    cfg.width = w;
    cfg.height = h;
    reset(sendReset: false);
    _sendConfig();
  }

  void setCellCm(double cm) {
    cfg.cellM = cm / 100;
    _sendConfig();
    notifyListeners();
  }

  void _onLine(String l) {
    final p = l.split(',');
    int? n(int i) => i < p.length ? int.tryParse(p[i].trim()) : null;
    switch (p[0].trim()) {
      case 'POS':
        final x = n(1), y = n(2);
        if (x != null && y != null) {
          robot = Pt(x, y);
          heading = n(3) ?? heading;
          final i = path.indexOf(robot!);
          if (i > 0) path = path.sublist(i);
        }
        break;
      case 'STATUS':
        const m = {
          'NAVIGATING': Mission.navigating,
          'REPLANNING': Mission.replanning,
          'ARRIVED': Mission.arrived,
          'ERROR': Mission.error,
          'STOPPED': Mission.stopped,
          'READY': Mission.ready,
        };
        final s = p.length > 1 ? m[p[1].trim()] : null;
        if (s != null) state = s;
        break;
      case 'OBSTACLE':
        final x = n(1), y = n(2);
        if (x != null && y != null) {
          final o = Pt(x, y);
          if (o != robot && o != dest) obs[o] = ObsType.detected;
          state = Mission.obstacleDetected;
          if (robot != null && dest != null) {
            path = aStar(robot!, dest!, obs.keys.toSet(), cfg.width, cfg.height) ?? [];
          }
        }
        break;
    }
    notifyListeners();
  }
}