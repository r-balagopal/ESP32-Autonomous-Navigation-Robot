import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_bluetooth_serial_plus/flutter_bluetooth_serial_plus.dart';

/// Represents a Bluetooth device.
class Dev {
  final String name;
  final String address;

  Dev(this.name, this.address);
}

/// Transport abstraction.
///
/// The app communicates with the robot through this interface,
/// so BLE can be added later without changing the rest of the app.
abstract class RobotLink {
  /// Emits one complete protocol line at a time.
  Stream<String> get lines;

  /// Emits true when connected and false when disconnected.
  Stream<bool> get connection;

  /// Current connection state.
  bool get isConnected;

  /// Last connected Bluetooth address.
  String? get lastAddress;

  /// Scan for available Bluetooth devices.
  Future<List<Dev>> scan();

  /// Connect to a Bluetooth device using its address.
  Future<void> connect(String address);

  /// Disconnect from the current device.
  Future<void> disconnect();

  /// Send one protocol line to the robot.
  void send(String line);
}

/// Bluetooth Classic implementation of RobotLink.
///
/// Designed for HC-05 / HC-06 modules.
class ClassicLink implements RobotLink {
  final StreamController<String> _lines =
      StreamController<String>.broadcast();

  final StreamController<bool> _conn =
      StreamController<bool>.broadcast();

  BluetoothConnection? _c;

  String _buf = '';

  String? _last;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<bool> get connection => _conn.stream;

  @override
  bool get isConnected => _c?.isConnected ?? false;

  @override
  String? get lastAddress => _last;

  @override
  Future<List<Dev>> scan() async {
    final Map<String, Dev> found = {};

    final bt = FlutterBluetoothSerial.instance;

    // Make sure Bluetooth is enabled.
    final enabled = await bt.isEnabled ?? false;

    if (!enabled) {
      await bt.requestEnable();
    }

    // Add already-paired devices first.
    try {
      final bondedDevices = await bt.getBondedDevices();

      for (final device in bondedDevices) {
        final address = device.address;

        found[address] = Dev(
          device.name ?? address,
          address,
        );
      }
    } catch (_) {
      // Ignore errors while reading bonded devices.
    }

    // Perform discovery for new devices.
    try {
      await for (final result in bt
          .startDiscovery()
          .timeout(
            const Duration(seconds: 8),
            onTimeout: (sink) {
              sink.close();
            },
          )) {
        final device = result.device;
        final address = device.address;

        found[address] = Dev(
          device.name ?? address,
          address,
        );
      }
    } catch (_) {
      // Discovery can fail if Bluetooth permissions/state change.
    }

    return found.values.toList();
  }
  @override
  Future<void> connect(String address) async {
    await disconnect();
    _last = address;
    final c = await BluetoothConnection.toAddress(address);
    _c = c;
    _buf = '';
    _conn.add(true);
    c.input.listen((Uint8List d) {
      _buf += utf8.decode(d, allowMalformed: true).replaceAll('\r', '\n');
      int i;
      while ((i = _buf.indexOf('\n')) >= 0) {
        final l = _buf.substring(0, i).trim();
        _buf = _buf.substring(i + 1);
        if (l.isNotEmpty) _lines.add(l);
      }
    }).onDone(() {
      _c = null;
      _conn.add(false);
    });
  }

  @override
  Future<void> disconnect() async {
    final connection = _c;

    _c = null;
    _buf = '';

    if (connection != null) {
      try {
        await connection.close();
      } catch (_) {
        // Ignore close errors.
      }

      _conn.add(false);
    }
  }

  @override
  void send(String line) {
    final connection = _c;

    if (connection == null || !connection.isConnected) {
      return;
    }

    final data = Uint8List.fromList(
      utf8.encode('$line\n'),
    );

    connection.output.add(data);

    // Make sure the data is flushed immediately.
    connection.output.allSent;
  }

  void _handleDisconnect() {
    if (_c != null) {
      _c = null;
      _conn.add(false);
    }
  }

  /// Call this when the app is completely finished with the link.
  void dispose() {
    _lines.close();
    _conn.close();
  }
}