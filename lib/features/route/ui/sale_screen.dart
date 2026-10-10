import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../shared/format.dart';
import '../../auth/auth_controller.dart';
import '../../masterdata/master_data_repository.dart';
import '../../masterdata/models.dart';
import '../route_models.dart';
import '../route_service.dart';
import 'invoice_screen.dart';
import 'route_providers.dart';

/// Deliver an order and/or sell off the truck at a stop, take payment, and issue the invoice with the handheld's
/// next number. Every rule ZARI would apply is checked live, before the number is used.
class SaleScreen extends ConsumerStatefulWidget {
  const SaleScreen({super.key, required this.tripId, required this.customerId, required this.customerName});
  final String tripId;
  final String customerId;
  final String customerName;

  @override
  ConsumerState<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends ConsumerState<SaleScreen> {
  RouteTripView? _view;
  final Map<String, ItemEntry?> _catalog = {};
  List<RefRecord> _methods = const [];
  OrderInfo? _order;
  final List<SaleLineDraft> _lines = [];
  final Map<String, TextEditingController> _qtyCtl = {};
  final Map<String, RefusalDraft> _refusals = {};
  final _cashCtl = TextEditingController();
  final _otherAmountCtl = TextEditingController();
  final _otherRefCtl = TextEditingController();
  final _receivedCtl = TextEditingController();
  RefRecord? _otherMethod;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [..._qtyCtl.values, _cashCtl, _otherAmountCtl, _otherRefCtl, _receivedCtl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final view = await ref.read(routeServiceProvider).trip(widget.tripId);
    if (view == null) return;
    final repo = ref.read(masterDataRepositoryProvider);
    for (final id in view.ledger.items.keys) {
      _catalog[id] = await repo.itemEntry(id, branchId: view.trip.branchId);
    }
    final methods = await repo.refList(RefEntity.paymentMethod);
    final orders = view.ledger.openOrdersFor(widget.customerId);
    setState(() {
      _view = view;
      _methods = methods;
      _otherMethod = methods.where((m) => m.code.toUpperCase() != 'CASH').firstOrNull;
      if (orders.isNotEmpty) _selectOrder(orders.first);
    });
  }

  void _selectOrder(OrderInfo? order) {
    _lines.removeWhere((l) => l.salesOrderLineId != null);
    _refusals.clear();
    _order = order;
    if (order == null) return;
    final ledger = _view!.ledger;
    for (final ol in order.lines) {
      final open = ledger.orderLineOpen(ol.salesOrderLineId);
      if (open <= 0.00001) continue;
      final line = _lineFor(ol.itemId, qty: open, price: ol.unitPrice, discount: ol.discountPct, soLineId: ol.salesOrderLineId);
      _lines.insert(0, line);
    }
  }

  SaleLineDraft _lineFor(String itemId, {required double qty, required double price, double discount = 0, String? soLineId}) {
    final truck = _view!.ledger.items[itemId];
    final item = _catalog[itemId]?.item;
    final line = SaleLineDraft(
      itemId: itemId,
      code: truck?.code ?? item?.code ?? itemId,
      name: truck?.name ?? item?.name ?? itemId,
      uomId: truck?.uomId ?? item?.baseUomId ?? '',
      vatType: item?.vatType ?? VatType.vatable,
      qty: qty,
      unitPrice: price,
      discountPct: discount,
      salesOrderLineId: soLineId,
      allowNegativeStock: item?.allowNegativeStock ?? false,
    );
    _qtyCtl[_key(line)] = TextEditingController(text: qty == 0 ? '' : _fmt(qty));
    return line;
  }

  static String _key(SaleLineDraft l) => l.salesOrderLineId ?? 'van-${l.itemId}';
  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  /// What the order still needs, minus what's being delivered now — the shortfall needs a reason.
  double _shortfall(OrderLineInfo ol) {
    final open = _view!.ledger.orderLineOpen(ol.salesOrderLineId);
    final delivered = _lines.where((l) => l.salesOrderLineId == ol.salesOrderLineId).fold(0.0, (s, l) => s + l.qty);
    return open - delivered;
  }

  SaleDraft _draft() {
    final cash = _methods.where((m) => m.code.toUpperCase() == 'CASH').firstOrNull;
    final tenders = <TenderDraft>[
      if (cash != null && (parseNum(_cashCtl.text) ?? 0) > 0)
        TenderDraft(paymentMethodId: cash.id, code: cash.code, name: cash.name, amount: parseNum(_cashCtl.text)!),
      if (_otherMethod != null && (parseNum(_otherAmountCtl.text) ?? 0) > 0)
        TenderDraft(
            paymentMethodId: _otherMethod!.id,
            code: _otherMethod!.code,
            name: _otherMethod!.name,
            amount: parseNum(_otherAmountCtl.text)!,
            referenceNo: _otherRefCtl.text.trim()),
    ];
    final refusals = <RefusalDraft>[];
    for (final ol in _order?.lines ?? const <OrderLineInfo>[]) {
      final short = _shortfall(ol);
      if (short > 0.00001) {
        final r = _refusals.putIfAbsent(ol.salesOrderLineId,
            () => RefusalDraft(salesOrderLineId: ol.salesOrderLineId, itemId: ol.itemId, qty: short, reasonCode: ''));
        r.qty = short;
        refusals.add(r);
      }
    }
    return SaleDraft(
      tripId: widget.tripId,
      customerId: widget.customerId,
      customerName: widget.customerName,
      salesOrderId: _order?.id,
      headerDiscountPct: _order?.discountPct,
      lines: _lines,
      refusals: refusals,
      tenders: tenders,
      receivedByName: _receivedCtl.text,
    );
  }

  Future<void> _addItem() async {
    final ledger = _view!.ledger;
    final available = ledger.items.values.where((i) => i.onTruck > 0.00001).toList()..sort((a, b) => a.code.compareTo(b.code));
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(children: [
          const ListTile(title: Text('Sell from the truck')),
          for (final i in available)
            ListTile(
              title: Text(i.name),
              subtitle: Text('${i.code} · ${qty(i.onTruck)} on truck · ${money(_catalog[i.itemId]?.price)}'),
              onTap: () => Navigator.pop(ctx, i.itemId),
            ),
          if (available.isEmpty) const ListTile(title: Text('Nothing left on the truck.')),
        ]),
      ),
    );
    if (picked == null) return;
    final existing = _lines.where((l) => l.itemId == picked && l.salesOrderLineId == null).firstOrNull;
    setState(() {
      if (existing != null) {
        existing.qty += 1;
        _qtyCtl[_key(existing)]!.text = _fmt(existing.qty);
      } else {
        final price = _catalog[picked]?.price;
        if (price == null) {
          showError(context, StateError('${ledger.items[picked]?.code}: no selling price at this branch — it can only go out on an order.'));
          return;
        }
        _lines.add(_lineFor(picked, qty: 1, price: price));
      }
    });
  }

  Future<void> _submit(SaleCheck check) async {
    final draft = _draft();
    final missingReason = draft.refusals.where((r) => r.reasonCode.isEmpty).toList();
    if (missingReason.isNotEmpty) return showError(context, StateError('Choose why the rest of the order was not delivered.'));
    final f = check.figures;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Issue invoice ${_view!.series.nextFormatted}?'),
        content: Text('Total ${money(f.totals.total)}\n'
            'Paid ${money(f.applied)}${f.change > 0 ? ' · change ${money(f.change)}' : ''}'
            '${f.charged > 0.004 ? '\nCharged to account ${money(f.charged)}' : ''}\n\n'
            'Once issued, the number can only be voided — not changed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Issue & print')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final sale = await ref.read(routeServiceProvider).recordSale(ref.read(authControllerProvider).session!.userId, draft);
      afterRouteAction(ref);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => InvoiceScreen(tripId: widget.tripId, eventId: sale.id, autoPrint: true)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    if (view == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final ledger = view.ledger;
    final orders = ledger.openOrdersFor(widget.customerId);
    final check = checkSale(ledger, _draft(), onTheRoad: view.onTheRoad);
    final f = check.figures;
    final reasons = view.latest.refusalReasons;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(widget.customerName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          if (orders.isNotEmpty)
            DropdownButtonFormField<String?>(
              value: _order?.id,
              decoration: const InputDecoration(labelText: 'Order to deliver'),
              items: [
                for (final o in orders) DropdownMenuItem(value: o.id, child: Text(o.soNo)),
                const DropdownMenuItem(value: null, child: Text('No order — van sale only')),
              ],
              onChanged: (id) => setState(() => _selectOrder(orders.where((o) => o.id == id).firstOrNull)),
            ),
          const SizedBox(height: 8),
          for (final line in _lines) _lineTile(line, ledger.onTruck(line.itemId), reasons),
          TextButton.icon(onPressed: _addItem, icon: const Icon(Icons.add), label: const Text('Add item from the truck')),
          const Divider(),
          _row('Total', money(f.totals.total), textTheme.titleLarge),
          if (f.totals.discount > 0.004) _row('Discount', '−${money(f.totals.discount)}', textTheme.bodyMedium),
          _row('VAT included', money(f.totals.vat), textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: _cashCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Cash received',
              suffixIcon: TextButton(
                onPressed: () => setState(() => _cashCtl.text = f.totals.total.toStringAsFixed(2)),
                child: const Text('Exact'),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_otherMethod != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  value: _otherMethod!.id,
                  decoration: const InputDecoration(labelText: 'Other payment'),
                  items: [
                    for (final m in _methods.where((m) => m.code.toUpperCase() != 'CASH'))
                      DropdownMenuItem(value: m.id, child: Text(m.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (id) => setState(() => _otherMethod = _methods.firstWhere((m) => m.id == id)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _otherAmountCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
            if ((parseNum(_otherAmountCtl.text) ?? 0) > 0)
              TextField(
                controller: _otherRefCtl,
                decoration: const InputDecoration(labelText: 'Reference no.'),
                onChanged: (_) => setState(() {}),
              ),
          ],
          const SizedBox(height: 8),
          if (f.change > 0) _row('Change', money(f.change), textTheme.titleMedium),
          if (f.charged > 0.004)
            _row('Charged to account', money(f.charged), textTheme.titleMedium?.copyWith(color: Colors.orange.shade800)),
          TextField(controller: _receivedCtl, decoration: const InputDecoration(labelText: 'Received by (name)')),
          if (check.errors.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final e in check.errors)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $e', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _busy || !check.ok ? null : () => _submit(check),
            icon: const Icon(Icons.print),
            label: Text('Issue invoice ${view.series.nextFormatted} · ${money(f.totals.total)}'),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, TextStyle? style) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [Expanded(child: Text(label, style: style)), Text(value, style: style)]),
      );

  Widget _lineTile(SaleLineDraft line, double onTruck, List<RefusalReason> reasons) {
    final ol = _order?.lines.where((l) => l.salesOrderLineId == line.salesOrderLineId).firstOrNull;
    final short = ol == null ? 0.0 : _shortfall(ol);
    final refusal = ol == null ? null : _refusals[ol.salesOrderLineId];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(line.name, style: Theme.of(context).textTheme.titleSmall),
                Text('${line.code} · ${money(line.unitPrice)}${line.discountPct > 0 ? ' less ${qty(line.discountPct)}%' : ''}'
                    ' · ${qty(onTruck)} on truck${ol != null ? ' · ordered ${qty(_view!.ledger.orderLineOpen(ol.salesOrderLineId))}' : ''}'),
              ]),
            ),
            SizedBox(
              width: 96,
              child: TextField(
                controller: _qtyCtl[_key(line)],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.end,
                decoration: InputDecoration(labelText: ol != null ? 'Delivered' : 'Qty', isDense: true),
                onChanged: (v) => setState(() => line.qty = parseNum(v) ?? 0),
              ),
            ),
            if (ol == null)
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _lines.remove(line)),
              ),
          ]),
          if (ol != null && short > 0.00001) ...[
            const SizedBox(height: 6),
            Text('${qty(short)} not delivered — why?', style: TextStyle(color: Colors.orange.shade800)),
            DropdownButton<String>(
              isExpanded: true,
              value: (refusal?.reasonCode ?? '').isEmpty ? null : refusal!.reasonCode,
              hint: const Text('Choose a reason'),
              items: [for (final r in reasons) DropdownMenuItem(value: r.code, child: Text(r.label))],
              onChanged: (code) => setState(() {
                final r = _refusals.putIfAbsent(ol.salesOrderLineId,
                    () => RefusalDraft(salesOrderLineId: ol.salesOrderLineId, itemId: ol.itemId, qty: short, reasonCode: ''));
                r.reasonCode = code ?? '';
              }),
            ),
            if (refusal?.reasonCode == RefusalReason.other)
              TextField(
                decoration: const InputDecoration(labelText: 'Explain', isDense: true),
                onChanged: (v) => setState(() => refusal!.notes = v),
              ),
          ],
        ]),
      ),
    );
  }
}
