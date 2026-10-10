import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../auth/auth_controller.dart';
import '../../sync/outbox.dart';
import '../printing/escpos.dart';
import '../printing/invoice_layout.dart';
import '../printing/printer_service.dart';
import '../route_ledger.dart';
import 'printer_setup_screen.dart';
import 'route_forms.dart';
import 'route_providers.dart';
import 'trip_screen.dart';

/// The issued invoice: on-screen copy (same lines as the printout), print / reprint, the customer's signature,
/// and — only while it hasn't reached ZARI — void.
class InvoiceScreen extends ConsumerStatefulWidget {
  const InvoiceScreen({super.key, required this.tripId, required this.eventId, this.autoPrint = false});
  final String tripId;
  final String eventId;
  final bool autoPrint;

  @override
  ConsumerState<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends ConsumerState<InvoiceScreen> {
  int _width = 32;
  bool _printing = false;
  bool _autoPrinted = false;

  @override
  void initState() {
    super.initState();
    ref.read(printerServiceProvider).choice().then((c) {
      if (mounted && c != null) setState(() => _width = c.width);
    });
  }

  Future<void> _print(RouteEvent sale, {required bool reprint}) async {
    final view = await ref.read(routeServiceProvider).trip(widget.tripId);
    if (view == null) return;
    setState(() => _printing = true);
    try {
      await ref.read(printerServiceProvider).printLines(invoiceLines(view.latest, sale, width: _width, reprint: reprint));
      await ref.read(routeServiceProvider).markPrinted(sale);
      afterRouteAction(ref);
    } on PrinterException catch (e) {
      if (!mounted) return;
      final setup = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Not printed'),
          content: Text('${e.message}\n\nThe invoice is saved — you can print it from here any time.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('OK')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Printer setup')),
          ],
        ),
      );
      if (setup == true && mounted) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrinterSetupScreen()));
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _void(RouteEvent sale) async {
    final reason = await askReason(context,
        title: 'Void ${sale.invoiceNumber}?',
        message: 'Only for an invoice that must not stand (e.g. printer jam, wrong customer). Collect the printed copy. '
            'Issue a new invoice afterwards if the sale still goes ahead.');
    if (reason == null) return;
    try {
      await ref.read(routeServiceProvider).voidSale(sale, reason);
      afterRouteAction(ref);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _sign(RouteEvent sale) async {
    final result = await Navigator.of(context).push<(Uint8List, String)>(
        MaterialPageRoute(builder: (_) => SignatureScreen(initialName: sale.data['receivedByName'] as String?)));
    if (result == null) return;
    await ref.read(routeServiceProvider).attachSignature(ref.read(authControllerProvider).session!.userId, sale, result.$1, result.$2);
    afterRouteAction(ref);
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(routeTripProvider(widget.tripId)).valueOrNull;
    final outbox = ref.watch(routeOutboxProvider).valueOrNull ?? const {};
    final sale = view?.ledger.events.where((e) => e.id == widget.eventId).firstOrNull;
    if (view == null || sale == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final voided = sale.kind == RouteEventKind.voidNumber;
    final entry = sale.outboxId == null ? null : outbox[sale.outboxId];
    final canVoid = !voided && entry != null && entry.serverId == null &&
        entry.status != OutboxStatus.synced && entry.status != OutboxStatus.syncing;
    final printed = (sale.data['printCount'] as int? ?? 0) > 0;
    final lines = invoiceLines(view.latest, sale, width: _width, reprint: printed);

    if (widget.autoPrint && !_autoPrinted && !voided) {
      _autoPrinted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _print(sale, reprint: false));
    }

    return Scaffold(
      appBar: AppBar(title: Text(voided ? '${sale.invoiceNumber} (void)' : sale.invoiceNumber ?? 'Invoice')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (voided)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(leading: const Icon(Icons.block), title: Text('VOIDED — ${sale.data['voidReason'] ?? ''}')),
            ),
          if (entry != null && !voided)
            Text(
              switch (entry.status) {
                OutboxStatus.synced => 'In ZARI.',
                OutboxStatus.failed => 'ZARI rejected it: ${entry.lastError ?? ''} — open Sync & Queue.',
                OutboxStatus.needsReview => 'Needs review — open Sync & Queue.',
                _ => 'Saved on this device; it goes to ZARI when there is a connection.',
              },
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: _width == 48 ? 380 : 270,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final l in lines) _PreviewLine(l, voided: voided)],
              ),
            ),
          ),
          if (sale.data['signature'] != null)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('✓ Signature captured', textAlign: TextAlign.center)),
        ],
      ),
      bottomNavigationBar: voided
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _printing ? null : () => _print(sale, reprint: printed),
                      icon: const Icon(Icons.print),
                      label: Text(printed ? 'Reprint' : 'Print'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(onPressed: () => _sign(sale), icon: const Icon(Icons.draw_outlined), label: const Text('Sign')),
                  if (canVoid) ...[
                    const SizedBox(width: 8),
                    IconButton(tooltip: 'Void', onPressed: () => _void(sale), icon: const Icon(Icons.block)),
                  ],
                ]),
              ),
            ),
    );
  }
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine(this.line, {required this.voided});
  final PrintLine line;
  final bool voided;

  @override
  Widget build(BuildContext context) => Text(
        line.text,
        textAlign: switch (line.align) { PrintAlign.center => TextAlign.center, PrintAlign.right => TextAlign.right, _ => TextAlign.left },
        softWrap: false,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: line.big ? 18 : 11,
          height: 1.25,
          color: Colors.black,
          fontWeight: line.bold ? FontWeight.bold : FontWeight.normal,
          decoration: voided ? TextDecoration.lineThrough : null,
        ),
      );
}

/// Finger signature of whoever received the goods, saved as a PNG and uploaded with the sale.
class SignatureScreen extends StatefulWidget {
  const SignatureScreen({super.key, this.initialName});
  final String? initialName;

  @override
  State<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends State<SignatureScreen> {
  final List<List<Offset>> _strokes = [];
  late final _name = TextEditingController(text: widget.initialName ?? '');
  final _key = GlobalKey();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_strokes.isEmpty) return;
    final box = _key.currentContext!.findRenderObject() as RenderBox;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    _SignaturePainter(_strokes).paint(canvas, box.size);
    final image = await recorder.endRecording().toImage(box.size.width.ceil(), box.size.height.ceil());
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted || png == null) return;
    Navigator.pop(context, (png.buffer.asUint8List(), _name.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Received by'), actions: [
        TextButton(onPressed: () => setState(_strokes.clear), child: const Text('Clear')),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name of person receiving')),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              key: _key,
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black26)),
              child: GestureDetector(
                onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
                onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
                child: ClipRect(child: CustomPaint(painter: _SignaturePainter(_strokes), size: Size.infinite)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _strokes.isEmpty ? null : _save, child: const Text('Save signature')),
        ]),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes);
  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length == 1) canvas.drawPoints(ui.PointMode.points, s, paint);
      for (var i = 1; i < s.length; i++) {
        canvas.drawLine(s[i - 1], s[i], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter old) => true;
}
