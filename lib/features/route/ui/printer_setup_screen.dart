import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../printing/escpos.dart';
import '../printing/printer_service.dart';

/// Pick the handheld's printer: a paired Bluetooth thermal printer, or the built-in one (it shows up as a paired
/// device too, e.g. "InnerPrinter"). Pair new printers in Android's Bluetooth settings first.
class PrinterSetupScreen extends ConsumerStatefulWidget {
  const PrinterSetupScreen({super.key});

  @override
  ConsumerState<PrinterSetupScreen> createState() => _PrinterSetupScreenState();
}

class _PrinterSetupScreenState extends ConsumerState<PrinterSetupScreen> {
  PrinterChoice? _choice;
  List<PairedPrinter> _paired = const [];
  String? _error;
  bool _loading = true;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(printerServiceProvider);
    final choice = await service.choice();
    List<PairedPrinter> paired = const [];
    String? error;
    try {
      paired = await service.paired();
    } on PrinterException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Bluetooth is not available on this device.';
    }
    if (!mounted) return;
    setState(() {
      _choice = choice;
      _paired = paired;
      _error = error;
      _loading = false;
    });
  }

  Future<void> _choose(PairedPrinter p) async {
    final c = PrinterChoice(mac: p.mac, name: p.name, width: _choice?.width ?? 32);
    await ref.read(printerServiceProvider).choose(c);
    setState(() => _choice = c);
  }

  Future<void> _setWidth(int width) async {
    if (_choice == null) return;
    final c = PrinterChoice(mac: _choice!.mac, name: _choice!.name, width: width);
    await ref.read(printerServiceProvider).choose(c);
    setState(() => _choice = c);
  }

  Future<void> _test() async {
    setState(() => _printing = true);
    final w = _choice?.width ?? 32;
    try {
      await ref.read(printerServiceProvider).printLines([
        const PrintLine('ZARI test print', align: PrintAlign.center, bold: true),
        PrintLine(Cols.rule(w)),
        PrintLine(Cols.row('Paper width', '$w characters', w)),
        const PrintLine('If this line is not cut off, the width is right.'),
      ]);
    } on PrinterException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Printer')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (_error != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(title: Text(_error!), trailing: TextButton(onPressed: _load, child: const Text('Retry'))),
                ),
              Text('Paired printers', style: Theme.of(context).textTheme.titleMedium),
              if (_paired.isEmpty && _error == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No paired devices. Pair the printer in Android Settings → Bluetooth, then come back.'),
                ),
              for (final p in _paired)
                RadioListTile<String>(
                  value: p.mac,
                  groupValue: _choice?.mac,
                  title: Text(p.name.isEmpty ? p.mac : p.name),
                  subtitle: Text(p.mac),
                  onChanged: (_) => _choose(p),
                ),
              const SizedBox(height: 16),
              Text('Paper', style: Theme.of(context).textTheme.titleMedium),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 32, label: Text('58 mm')),
                  ButtonSegment(value: 48, label: Text('80 mm')),
                ],
                selected: {_choice?.width ?? 32},
                onSelectionChanged: _choice == null ? null : (s) => _setWidth(s.first),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _choice == null || _printing ? null : _test,
                icon: const Icon(Icons.print),
                label: Text(_choice == null ? 'Choose a printer first' : 'Test print on ${_choice!.name}'),
              ),
            ]),
    );
  }
}
