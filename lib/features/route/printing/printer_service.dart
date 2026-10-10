import 'dart:convert';

import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../../../core/key_value_store.dart';
import 'escpos.dart';

class PrinterChoice {
  const PrinterChoice({required this.mac, required this.name, this.width = 32});

  final String mac;
  final String name;

  /// Characters per line: 32 for 58 mm paper, 48 for 80 mm.
  final int width;

  Map<String, dynamic> toJson() => {'mac': mac, 'name': name, 'width': width};
  factory PrinterChoice.fromJson(Map<String, dynamic> j) =>
      PrinterChoice(mac: j['mac'] as String, name: j['name'] as String, width: (j['width'] as num?)?.toInt() ?? 32);
}

class PairedPrinter {
  const PairedPrinter(this.name, this.mac);
  final String name;
  final String mac;
}

/// How bytes reach the printer. The Bluetooth one covers both external printers and built-in handheld printers
/// (e.g. Sunmi's "InnerPrinter"), which show up as a paired Bluetooth device.
abstract class PrinterTransport {
  Future<bool> permissionGranted();
  Future<bool> bluetoothOn();
  Future<List<PairedPrinter>> paired();
  Future<bool> connected();
  Future<bool> connect(String mac);
  Future<bool> write(List<int> bytes);
}

class BluetoothPrinterTransport implements PrinterTransport {
  @override
  Future<bool> permissionGranted() => PrintBluetoothThermal.isPermissionBluetoothGranted;
  @override
  Future<bool> bluetoothOn() => PrintBluetoothThermal.bluetoothEnabled;
  @override
  Future<List<PairedPrinter>> paired() async =>
      [for (final d in await PrintBluetoothThermal.pairedBluetooths) PairedPrinter(d.name, d.macAdress)];
  @override
  Future<bool> connected() => PrintBluetoothThermal.connectionStatus;
  @override
  Future<bool> connect(String mac) => PrintBluetoothThermal.connect(macPrinterAddress: mac);
  @override
  Future<bool> write(List<int> bytes) => PrintBluetoothThermal.writeBytes(bytes);
}

class PrinterException implements Exception {
  PrinterException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PrinterService {
  PrinterService(this._kv, {PrinterTransport? transport}) : _transport = transport ?? BluetoothPrinterTransport();

  final KeyValueStore _kv;
  final PrinterTransport _transport;
  static const _key = 'route.printer';

  Future<PrinterChoice?> choice() async {
    final raw = await _kv.read(_key);
    return raw == null ? null : PrinterChoice.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> choose(PrinterChoice c) => _kv.write(_key, jsonEncode(c.toJson()));

  Future<List<PairedPrinter>> paired() async {
    if (!await _transport.permissionGranted()) throw PrinterException('Allow "Nearby devices" (Bluetooth) for ZARI to print.');
    if (!await _transport.bluetoothOn()) throw PrinterException('Turn on Bluetooth to print.');
    return _transport.paired();
  }

  /// Prints the lines on the chosen printer, connecting first if needed.
  Future<void> printLines(List<PrintLine> lines) async {
    final c = await choice();
    if (c == null) throw PrinterException('Choose a printer first (Printer setup).');
    if (!await _transport.permissionGranted()) throw PrinterException('Allow "Nearby devices" (Bluetooth) for ZARI to print.');
    if (!await _transport.bluetoothOn()) throw PrinterException('Turn on Bluetooth to print.');
    if (!await _transport.connected() && !await _transport.connect(c.mac)) {
      throw PrinterException('Could not connect to ${c.name}. Is it on and nearby?');
    }
    if (!await _transport.write(EscPos.render(lines))) throw PrinterException('${c.name} did not accept the print. Try again.');
  }
}
