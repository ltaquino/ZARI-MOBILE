import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../shared/format.dart';
import '../../auth/auth_controller.dart';
import '../../masterdata/models.dart';
import '../printing/invoice_layout.dart';
import '../printing/printer_service.dart';
import '../route_models.dart';
import '../route_service.dart';
import 'route_providers.dart';

/// A required free-text reason (voids). Null when cancelled.
Future<String?> askReason(BuildContext context, {required String title, required String message}) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(message),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Reason'),
            onChanged: (_) => setState(() {}),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: ctl.text.trim().isEmpty ? null : () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Void'),
          ),
        ],
      ),
    ),
  );
}

String _userId(WidgetRef ref) => ref.read(authControllerProvider).session!.userId;

// ---------------------------------------------------------------- refused (no invoice)

/// The customer accepted none of (part of) their order — no invoice number is used. Each line needs a reason.
class RefusalScreen extends ConsumerStatefulWidget {
  const RefusalScreen({super.key, required this.tripId, required this.customerId, required this.customerName});
  final String tripId;
  final String customerId;
  final String customerName;

  @override
  ConsumerState<RefusalScreen> createState() => _RefusalScreenState();
}

class _RefusalScreenState extends ConsumerState<RefusalScreen> {
  OrderInfo? _order;
  final Map<String, RefusalDraft> _lines = {};
  final Map<String, TextEditingController> _qty = {};
  String _reasonForAll = '';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _setup(RouteTripView view, OrderInfo order) {
    _order = order;
    _lines.clear();
    for (final ol in order.lines) {
      final open = view.ledger.orderLineOpen(ol.salesOrderLineId);
      if (open <= 0.00001) continue;
      _lines[ol.salesOrderLineId] = RefusalDraft(salesOrderLineId: ol.salesOrderLineId, itemId: ol.itemId, qty: open, reasonCode: _reasonForAll);
      _qty[ol.salesOrderLineId] = TextEditingController(text: qty(open));
    }
  }

  Future<void> _save() async {
    if (_lines.values.any((l) => l.qty > 0 && l.reasonCode.isEmpty)) {
      return showError(context, StateError('Choose a reason for each item.'));
    }
    setState(() => _busy = true);
    try {
      await ref.read(routeServiceProvider).recordRefusal(
          _userId(ref), widget.tripId, widget.customerId, widget.customerName, _order!.id, _lines.values.toList());
      afterRouteAction(ref);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(routeTripProvider(widget.tripId)).valueOrNull;
    if (view == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final orders = view.ledger.openOrdersFor(widget.customerId);
    if (_order == null && orders.isNotEmpty) _setup(view, orders.first);
    final reasons = view.latest.refusalReasons;
    return Scaffold(
      appBar: AppBar(title: const Text('Not delivered')),
      body: _order == null
          ? const Center(child: Text('No open orders for this customer.'))
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text('${widget.customerName} did not accept:', style: Theme.of(context).textTheme.titleMedium),
              if (orders.length > 1)
                DropdownButton<String>(
                  value: _order!.id,
                  items: [for (final o in orders) DropdownMenuItem(value: o.id, child: Text(o.soNo))],
                  onChanged: (id) => setState(() => _setup(view, orders.firstWhere((o) => o.id == id))),
                ),
              DropdownButtonFormField<String>(
                value: _reasonForAll.isEmpty ? null : _reasonForAll,
                decoration: const InputDecoration(labelText: 'Reason (all items)'),
                items: [for (final r in reasons) DropdownMenuItem(value: r.code, child: Text(r.label))],
                onChanged: (v) => setState(() {
                  _reasonForAll = v ?? '';
                  for (final l in _lines.values) {
                    l.reasonCode = _reasonForAll;
                  }
                }),
              ),
              const SizedBox(height: 8),
              for (final l in _lines.values)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(view.ledger.items[l.itemId]?.name ?? l.itemId)),
                        SizedBox(
                          width: 70,
                          child: TextField(
                            controller: _qty[l.salesOrderLineId],
                            textAlign: TextAlign.end,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                            onChanged: (v) => setState(() => l.qty = parseNum(v) ?? 0),
                          ),
                        ),
                      ]),
                      DropdownButton<String>(
                        isExpanded: true,
                        value: l.reasonCode.isEmpty ? null : l.reasonCode,
                        hint: const Text('Reason'),
                        items: [for (final r in reasons) DropdownMenuItem(value: r.code, child: Text(r.label))],
                        onChanged: (v) => setState(() => l.reasonCode = v ?? ''),
                      ),
                      if (l.reasonCode == RefusalReason.other)
                        TextField(decoration: const InputDecoration(labelText: 'Explain'), onChanged: (v) => l.notes = v),
                    ]),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _busy ? null : _save, child: const Text('Record — goods stay on the truck')),
            ]),
    );
  }
}

// ---------------------------------------------------------------- customer return

class ReturnScreen extends ConsumerStatefulWidget {
  const ReturnScreen({super.key, required this.tripId, required this.customerId, required this.customerName});
  final String tripId;
  final String customerId;
  final String customerName;

  @override
  ConsumerState<ReturnScreen> createState() => _ReturnScreenState();
}

class _ReturnScreenState extends ConsumerState<ReturnScreen> {
  final List<SaleLineDraft> _lines = [];
  final Map<String, bool> _damaged = {};
  final _reason = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _add(RouteTripView view) async {
    final branchId = view.trip.branchId;
    final repo = ref.read(masterDataRepositoryProvider);
    final candidates = view.ledger.items.values.toList()..sort((a, b) => a.code.compareTo(b.code));
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(children: [
          const ListTile(title: Text('Item returned')),
          for (final i in candidates) ListTile(title: Text(i.name), subtitle: Text(i.code), onTap: () => Navigator.pop(ctx, i.itemId)),
        ]),
      ),
    );
    if (picked == null || _lines.any((l) => l.itemId == picked)) return;
    final entry = await repo.itemEntry(picked, branchId: branchId);
    final truck = view.ledger.items[picked]!;
    setState(() => _lines.add(SaleLineDraft(
          itemId: picked,
          code: truck.code,
          name: truck.name,
          uomId: truck.uomId,
          vatType: entry?.item.vatType ?? VatType.vatable,
          qty: 1,
          unitPrice: entry?.price ?? 0,
        )));
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(routeServiceProvider).recordReturn(
          _userId(ref), widget.tripId, widget.customerId, widget.customerName, _lines, _damaged, _reason.text);
      afterRouteAction(ref);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(routeTripProvider(widget.tripId)).valueOrNull;
    if (view == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text('Return · ${widget.customerName}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Good items go back on the truck and can be sold again. Damaged ones go to the branch Damaged warehouse at close.'),
        for (final l in _lines)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Row(children: [
                  Expanded(child: Text(l.name)),
                  SizedBox(
                    width: 64,
                    child: TextFormField(
                      initialValue: qty(l.qty),
                      textAlign: TextAlign.end,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                      onChanged: (v) => l.qty = parseNum(v) ?? 0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: TextFormField(
                      initialValue: l.unitPrice.toStringAsFixed(2),
                      textAlign: TextAlign.end,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Price', isDense: true),
                      onChanged: (v) => l.unitPrice = parseNum(v) ?? 0,
                    ),
                  ),
                ]),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Damaged'),
                  value: _damaged[l.itemId] == true,
                  onChanged: (v) => setState(() => _damaged[l.itemId] = v),
                ),
              ]),
            ),
          ),
        TextButton.icon(onPressed: () => _add(view), icon: const Icon(Icons.add), label: const Text('Add item')),
        TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason (optional)')),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy || _lines.isEmpty ? null : _save, child: const Text('Record return')),
      ]),
    );
  }
}

// ---------------------------------------------------------------- collection of older invoices

Future<void> showCollectionSheet(BuildContext context, WidgetRef ref, RouteTripView view, String customerId, String customerName) async {
  final methods = await ref.read(masterDataRepositoryProvider).refList(RefEntity.paymentMethod);
  if (!context.mounted) return;
  final owes = view.ledger.customerOwes(customerId);
  final amount = TextEditingController(text: owes.toStringAsFixed(2));
  final reference = TextEditingController();
  RefRecord? method = methods.where((m) => m.code.toUpperCase() == 'CASH').firstOrNull ?? methods.firstOrNull;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final value = parseNum(amount.text) ?? 0;
      final allocations = ref.read(routeServiceProvider).collectionAllocations(view, customerId, value);
      final isCash = method?.code.toUpperCase() == 'CASH';
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(ctx).bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Collect from $customerName', style: Theme.of(ctx).textTheme.titleLarge),
          Text('Owes ${money(owes)} — paid to the oldest invoices first.'),
          const SizedBox(height: 8),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount'),
            onChanged: (_) => setState(() {}),
          ),
          DropdownButtonFormField<String>(
            value: method?.id,
            decoration: const InputDecoration(labelText: 'Paid by'),
            items: [for (final m in methods) DropdownMenuItem(value: m.id, child: Text(m.name))],
            onChanged: (id) => setState(() => method = methods.firstWhere((m) => m.id == id)),
          ),
          if (!isCash) TextField(controller: reference, decoration: const InputDecoration(labelText: 'Reference no.')),
          const SizedBox(height: 8),
          for (final a in allocations) Text('→ ${a['label']}: ${money(a['amount'] as double)}', style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: method == null || value <= 0
                ? null
                : () async {
                    try {
                      await ref.read(routeServiceProvider).recordCollection(
                          _userId(ref),
                          view.id,
                          customerId,
                          customerName,
                          TenderDraft(
                              paymentMethodId: method!.id, code: method!.code, name: method!.name, amount: value, referenceNo: reference.text.trim()));
                      afterRouteAction(ref);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      if (ctx.mounted) showError(ctx, e);
                    }
                  },
            child: const Text('Record collection'),
          ),
        ]),
      );
    }),
  );
}

// ---------------------------------------------------------------- end of trip

/// Count what's left on the truck and hand in the cash. Goes to the branch manager to close.
class EndTripScreen extends ConsumerStatefulWidget {
  const EndTripScreen({super.key, required this.tripId});
  final String tripId;

  @override
  ConsumerState<EndTripScreen> createState() => _EndTripScreenState();
}

class _EndTripScreenState extends ConsumerState<EndTripScreen> {
  final Map<String, TextEditingController> _counts = {};
  TextEditingController? _cash;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [..._counts.values, if (_cash != null) _cash!]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _end(RouteTripView view) async {
    final counts = <String, double>{};
    for (final e in _counts.entries) {
      final v = parseNum(e.value.text);
      if (v == null || v < 0) return showError(context, StateError('Count every item (0 if none left).'));
      counts[e.key] = v;
    }
    final cash = parseNum(_cash!.text) ?? -1;
    final short = view.ledger.cashExpected - cash;
    final diffs = view.ledger.countSheet.where((i) => (counts[i.itemId] ?? 0) != i.onTruck).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End the trip?'),
        content: Text([
          'Cash handed in ${money(cash)} (expected ${money(view.ledger.cashExpected)}).',
          if (short.abs() > 0.004) short > 0 ? 'Cash short by ${money(short)}.' : 'Cash over by ${money(-short)}.',
          if (diffs.isNotEmpty) '${diffs.length} item(s) counted differently from what should be on the truck.',
          '\nNothing more can be recorded on this trip after this.',
        ].join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End trip')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(routeServiceProvider).endTrip(_userId(ref), view.id, counts, cash);
      afterRouteAction(ref);
      if (!mounted) return;
      final printer = ref.read(printerServiceProvider);
      final width = (await printer.choice())?.width ?? 32;
      try {
        await printer.printLines(tripSummaryLines(view.latest, view.ledger, width: width, counts: counts, cashRemitted: cash));
      } on PrinterException catch (_) {
        // The summary slip is a convenience; the trip has ended regardless.
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(routeTripProvider(widget.tripId)).valueOrNull;
    if (view == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final sheet = view.ledger.countSheet;
    for (final i in sheet) {
      _counts.putIfAbsent(i.itemId, () => TextEditingController(text: qty(i.onTruck)));
    }
    _cash ??= TextEditingController(text: view.ledger.cashExpected.toStringAsFixed(2));
    return Scaffold(
      appBar: AppBar(title: const Text('End trip')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Count what is left on the truck', style: Theme.of(context).textTheme.titleMedium),
        for (final i in sheet)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(i.name),
            subtitle: Text('${i.code} · should be ${qty(i.onTruck)}${i.returnedDamaged > 0 ? ' (+${qty(i.returnedDamaged)} damaged returns, not counted here)' : ''}'),
            trailing: SizedBox(
              width: 80,
              child: TextField(
                controller: _counts[i.itemId],
                textAlign: TextAlign.end,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Counted', isDense: true),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Cash', style: Theme.of(context).textTheme.titleMedium),
        Text('Expected from this trip: ${money(view.ledger.cashExpected)}'),
        const SizedBox(height: 12),
        TextField(
          controller: _cash,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Cash handed in'),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : () => _end(view),
          icon: const Icon(Icons.flag),
          label: const Text('End trip and hand in'),
        ),
      ]),
    );
  }
}
