import 'dart:math';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'controller.dart';
import 'link.dart';
import 'models.dart';

// ---------------- Map ----------------
class MapView extends StatelessWidget {
  const MapView({super.key});

  void _hit(Offset o, double cs, bool drag) {
    final x = (o.dx / cs).floor();
    final y = ctrl.cfg.height - 1 - (o.dy / cs).floor();
    if (x < 0 || y < 0 || x >= ctrl.cfg.width || y >= ctrl.cfg.height) return;
    ctrl.tap(Pt(x, y), drag: drag);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final w = ctrl.cfg.width, h = ctrl.cfg.height;
        final cs = min(box.maxWidth / w, box.maxHeight / h); // square cells
        return Center(
          child: SizedBox(
            width: cs * w,
            height: cs * h,
            child: GestureDetector(
              onTapDown: (d) => _hit(d.localPosition, cs, false),
              onPanUpdate: (d) {
                if (ctrl.mode == EditMode.obstacle) _hit(d.localPosition, cs, true);
              },
              child: CustomPaint(painter: MapPainter(ctrl)),
            ),
          ),
        );
      });
}

class MapPainter extends CustomPainter {
  MapPainter(this.c) : super(repaint: c);
  final Controller c;

  @override
  void paint(Canvas canvas, Size size) {
    final w = c.cfg.width, h = c.cfg.height, cs = size.width / w;
    Rect r(Pt p) => Rect.fromLTWH(p.x * cs, (h - 1 - p.y) * cs, cs, cs);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF2F2F2));
    final ln = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1;
    for (var i = 0; i <= w; i++) {
      canvas.drawLine(Offset(i * cs, 0), Offset(i * cs, size.height), ln);
    }
    for (var j = 0; j <= h; j++) {
      canvas.drawLine(Offset(0, j * cs), Offset(size.width, j * cs), ln);
    }
    c.obs.forEach((p, t) => canvas.drawRect(r(p).deflate(1),
        Paint()..color = t == ObsType.known ? Colors.grey.shade900 : Colors.red));
    if (c.dest != null) {
      final ct = r(c.dest!).center;
      canvas.drawCircle(ct, cs * .38, Paint()..color = Colors.green);
      canvas.drawCircle(ct, cs * .22, Paint()..color = Colors.white);
      canvas.drawCircle(ct, cs * .1, Paint()..color = Colors.green);
    }
    if (c.path.length > 1) {
      final pa = Path()..moveTo(r(c.path[0]).center.dx, r(c.path[0]).center.dy);
      for (final p in c.path.skip(1)) {
        pa.lineTo(r(p).center.dx, r(p).center.dy);
      }
      canvas.drawPath(
          pa,
          Paint()
            ..color = Colors.blue
            ..style = PaintingStyle.stroke
            ..strokeWidth = cs * .12
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
    }
    if (c.robot != null) {
      final ct = r(c.robot!).center;
      canvas.save();
      canvas.translate(ct.dx, ct.dy);
      canvas.rotate(c.heading * pi / 180);
      final a = Path()
        ..moveTo(0, -cs * .38)
        ..lineTo(cs * .3, cs * .3)
        ..lineTo(0, cs * .14)
        ..lineTo(-cs * .3, cs * .3)
        ..close();
      canvas.drawPath(a, Paint()..color = Colors.orange);
      canvas.drawPath(
          a,
          Paint()
            ..color = Colors.black
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

// ---------------- Home ----------------
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: const Text('Autonomous Navigator'),
            actions: [
              Icon(Icons.bluetooth,
                  color: ctrl.link.isConnected ? Colors.blue : Colors.grey),
              const SizedBox(width: 16),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              const Expanded(child: MapView()),
              const SizedBox(height: 8),
              Text('Robot ${ctrl.robot ?? '-'}    Destination ${ctrl.dest ?? '-'}    '
                  'Heading ${ctrl.heading}°'),
              Text('Status: ${ctrl.state.name.toUpperCase()}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<EditMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: EditMode.robot, label: Text('Robot')),
                  ButtonSegment(value: EditMode.destination, label: Text('Destination')),
                  ButtonSegment(value: EditMode.obstacle, label: Text('Obstacle')),
                ],
                selected: {ctrl.mode},
                onSelectionChanged: (s) => ctrl.setMode(s.first),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: OutlinedButton(
                        onPressed: ctrl.busy ? null : ctrl.calc,
                        child: const Text('CALCULATE PATH'))),
                const SizedBox(width: 8),
                Expanded(
                    child: FilledButton(
                        onPressed: ctrl.busy ? null : ctrl.start,
                        child: const Text('START MISSION'))),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade100,
                      foregroundColor: Colors.red.shade900),
                  onPressed: ctrl.stop,
                  child: const Text('STOP'),
                ),
              ),
            ]),
          ),
        ),
      );
}

// ---------------- Bluetooth ----------------
class BtPage extends StatefulWidget {
  const BtPage({super.key});
  @override
  State<BtPage> createState() => _BtPageState();
}

class _BtPageState extends State<BtPage> {
  List<Dev> devs = [];
  bool scanning = false;
  bool connecting = false;

    Future<void> _scan() async {
    final s = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    if (s[Permission.bluetoothScan]?.isGranted != true ||
        s[Permission.bluetoothConnect]?.isGranted != true) {
      messengerKey.currentState?.showSnackBar(const SnackBar(
          content: Text('Allow "Nearby devices" permission for this app')));
      openAppSettings();
      return;
    }
    setState(() => scanning = true);
    try {
      final d = await ctrl.link.scan();
      if (mounted) setState(() => devs = d);
    } catch (e) {
      messengerKey.currentState
          ?.showSnackBar(SnackBar(content: Text('Scan failed: $e')));
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  Future<void> _connect(String addr) async {
    setState(() => connecting = true);
    try {
      await ctrl.link.connect(addr);
    } catch (e) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text('Connect failed: $e')));
    }
    if (mounted) setState(() => connecting = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) {
          final on = ctrl.link.isConnected;
          return Scaffold(
            appBar: AppBar(title: const Text('Robot Connection')),
            body: Column(children: [
              ListTile(
                leading: Icon(on ? Icons.check_circle : Icons.cancel,
                    color: on ? Colors.green : Colors.grey),
                title: Text(on ? 'Connected' : 'Not connected'),
                trailing: on
                    ? TextButton(
                        onPressed: ctrl.link.disconnect, child: const Text('DISCONNECT'))
                    : (ctrl.link.lastAddress != null
                        ? TextButton(
                            onPressed: connecting
                                ? null
                                : () => _connect(ctrl.link.lastAddress!),
                            child: const Text('RECONNECT'))
                        : null),
              ),
              if (connecting || scanning) const LinearProgressIndicator(),
              Expanded(
                child: ListView(children: [
                  for (final d in devs)
                    ListTile(
                      leading: const Icon(Icons.memory),
                      title: Text(d.name),
                      subtitle: Text(d.address),
                      trailing: FilledButton(
                          onPressed: connecting ? null : () => _connect(d.address),
                          child: const Text('CONNECT')),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                      onPressed: scanning ? null : _scan,
                      icon: const Icon(Icons.search),
                      label: const Text('SCAN')),
                ),
              ),
            ]),
          );
        },
      );
}

// ---------------- Settings ----------------
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) {
          final c = ctrl.cfg;
          Widget slider(String label, double v, double min, double max, void Function(double) f) =>
              ListTile(
                title: Text(label),
                subtitle: Slider(
                    value: v,
                    min: min,
                    max: max,
                    divisions: (max - min).round(),
                    label: v.round().toString(),
                    onChanged: f),
              );
          return Scaffold(
            appBar: AppBar(title: const Text('Settings')),
            body: ListView(children: [
              slider('Grid width: ${c.width}', c.width.toDouble(), 4, 24,
                  (v) => ctrl.resize(v.round(), c.height)),
              slider('Grid height: ${c.height}', c.height.toDouble(), 4, 24,
                  (v) => ctrl.resize(c.width, v.round())),
              slider('Cell size: ${(c.cellM * 100).round()} cm', c.cellM * 100, 5, 100,
                  ctrl.setCellCm),
              ListTile(
                title: Text('Map: ${(c.width * c.cellM).toStringAsFixed(2)} m × '
                    '${(c.height * c.cellM).toStringAsFixed(2)} m'),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                    onPressed: ctrl.reset, child: const Text('RESET MAP')),
              ),
            ]),
          );
        },
      );
}
