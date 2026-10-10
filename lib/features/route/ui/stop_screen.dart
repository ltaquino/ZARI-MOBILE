import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/format.dart';
import '../route_ledger.dart';
import 'invoice_screen.dart';
import 'route_forms.dart';
import 'route_providers.dart';
import 'sale_screen.dart';

/// One customer on the route: what they ordered and still have open, what they owe, and the four things the
/// driver can do there — deliver/sell, record a refusal, take a return, collect a payment.
class StopScreen extends ConsumerWidget {
  const StopScreen({super.key, required this.tripId, required this.customerId});
  final String tripId;
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(routeTripProvider(tripId)).valueOrNull;
    if (view == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final stop = view.latest.stopFor(customerId);
    final name = stop?.customerName ?? 'Customer';
    final ledger = view.ledger;
    final orders = ledger.openOrdersFor(customerId);
    final owes = ledger.customerOwes(customerId);
    final history = ledger.events.where((e) => e.customerId == customerId).toList().reversed.toList();
    final onRoad = view.onTheRoad;

    void open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if ((stop?.address ?? '').isNotEmpty) Text(stop!.address!),
          if ((stop?.notes ?? '').isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(stop!.notes!, style: const TextStyle(fontStyle: FontStyle.italic))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _Fact('Owes now', money(owes), alert: owes > 0.004)),
            Expanded(child: _Fact('Credit limit', stop?.creditLimit == null ? 'No limit' : money(stop!.creditLimit))),
          ]),
          const SizedBox(height: 16),
          Text('To deliver', style: Theme.of(context).textTheme.titleMedium),
          if (orders.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No open orders for this customer.')),
          for (final o in orders)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(o.soNo, style: Theme.of(context).textTheme.titleSmall),
                  for (final l in o.lines.where((l) => ledger.orderLineOpen(l.salesOrderLineId) > 0.00001))
                    Text('${ledger.items[l.itemId]?.name ?? l.itemId} × ${qty(ledger.orderLineOpen(l.salesOrderLineId))}'
                        ' @ ${money(l.unitPrice)}${l.discountPct > 0 ? ' less ${qty(l.discountPct)}%' : ''}'),
                ]),
              ),
            ),
          const SizedBox(height: 12),
          if (onRoad) ...[
            FilledButton.icon(
              onPressed: () => open(SaleScreen(tripId: tripId, customerId: customerId, customerName: name)),
              icon: const Icon(Icons.receipt_long),
              label: Text(orders.isEmpty ? 'Sell (van sale)' : 'Deliver & invoice'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              if (orders.isNotEmpty)
                _Action(Icons.do_not_disturb_on_outlined, 'Refused',
                    () => open(RefusalScreen(tripId: tripId, customerId: customerId, customerName: name))),
              _Action(Icons.undo, 'Return', () => open(ReturnScreen(tripId: tripId, customerId: customerId, customerName: name))),
              _Action(Icons.payments_outlined, 'Collect',
                  owes > 0.004 ? () => showCollectionSheet(context, ref, view, customerId, name) : null),
            ]),
          ] else
            const Text('The trip has ended — nothing more can be recorded.'),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Done here', style: Theme.of(context).textTheme.titleMedium),
            for (final e in history)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(switch (e.kind) {
                  RouteEventKind.sale => Icons.receipt_long,
                  RouteEventKind.voidNumber => Icons.block,
                  RouteEventKind.refusal => Icons.do_not_disturb_on_outlined,
                  RouteEventKind.customerReturn => Icons.undo,
                  _ => Icons.payments_outlined,
                }),
                title: Text(switch (e.kind) {
                  RouteEventKind.sale => '${e.invoiceNumber} · ${money(e.amount('total'))}',
                  RouteEventKind.voidNumber => '${e.invoiceNumber} · voided',
                  RouteEventKind.refusal => 'Not delivered',
                  RouteEventKind.customerReturn => 'Return',
                  _ => 'Collected ${money(e.amount('amount'))}',
                }),
                subtitle: Text(dateTime(e.createdAt)),
                onTap: e.invoiceNumber != null && e.data['total'] != null
                    ? () => open(InvoiceScreen(tripId: tripId, eventId: e.id))
                    : null,
              ),
          ],
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.label, this.onPressed);
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon),
              const SizedBox(height: 4),
              Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
            ]),
          ),
        ),
      );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.alert = false});
  final String label;
  final String value;
  final bool alert;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(color: alert ? Theme.of(context).colorScheme.error : null)),
      ]);
}
