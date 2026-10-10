import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_exception.dart';
import '../../../core/providers.dart';
import '../../../shared/format.dart';
import '../../../shared/sync_widgets.dart';
import '../../auth/auth_controller.dart';
import '../../sales/customer_picker.dart';
import '../../sync/outbox.dart';
import '../../sync/sync_controller.dart';
import '../route_ledger.dart';
import '../route_models.dart';
import '../route_service.dart';
import 'invoice_screen.dart';
import 'route_forms.dart';
import 'route_home_screen.dart';
import 'route_providers.dart';
import 'sale_screen.dart';
import 'stop_screen.dart';

/// Sync state of each route outbox row, keyed by outbox id — shown next to every action in the activity list.
final routeOutboxProvider = FutureProvider<Map<String, OutboxEntry>>((ref) async {
  ref.watch(routeTickProvider);
  ref.watch(syncControllerProvider.select((s) => s.counts));
  final userId = ref.watch(authControllerProvider.select((a) => a.session?.userId));
  final all = await ref.read(outboxRepositoryProvider).list(userId: userId);
  return {for (final e in all.where((e) => OutboxType.isRoute(e.type))) e.id: e};
});

class TripScreen extends ConsumerWidget {
  const TripScreen({super.key, required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(routeTripProvider(tripId)).valueOrNull;
    if (view == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('This trip is no longer on the road.')));
    }
    final status = view.status;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(view.trip.tripNo),
          actions: [
            const SyncChip(),
            if (view.onTheRoad)
              PopupMenuButton<String>(
                onSelected: (v) => _menu(context, ref, view, v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'sale', child: Text('Sale to another customer')),
                  PopupMenuItem(value: 'void', child: Text('Void next invoice number')),
                  PopupMenuItem(value: 'end', child: Text('End trip')),
                ],
              ),
          ],
        ),
        body: Column(
          children: [
            const SessionBanner(),
            _TripHeader(view: view),
            if (status != TripStatus.loaded)
              const TabBar(tabs: [Tab(text: 'Stops'), Tab(text: 'Truck stock'), Tab(text: 'Activity')]),
            Expanded(
              child: status == TripStatus.loaded
                  ? _LoadedBody(view: view)
                  : TabBarView(children: [
                      _StopsTab(view: view),
                      _StockTab(view: view),
                      _ActivityTab(view: view),
                    ]),
            ),
          ],
        ),
        floatingActionButton: view.onTheRoad
            ? FloatingActionButton.extended(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => EndTripScreen(tripId: tripId))),
                icon: const Icon(Icons.flag_outlined),
                label: const Text('End trip'),
              )
            : null,
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, RouteTripView view, String action) async {
    switch (action) {
      case 'sale':
        final customer = await CustomerPickerScreen.pick(context);
        if (customer == null || !context.mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SaleScreen(tripId: tripId, customerId: customer.id, customerName: customer.name)));
      case 'void':
        final reason = await askReason(context,
            title: 'Void ${view.series.nextFormatted}?',
            message: 'Use this for a spoiled or blank printout. The number is used up so the series stays unbroken.');
        if (reason == null) return;
        try {
          await ref.read(routeServiceProvider).voidNextNumber(ref.read(authControllerProvider).session!.userId, tripId, reason);
          afterRouteAction(ref);
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      case 'end':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EndTripScreen(tripId: tripId)));
    }
  }
}

class _TripHeader extends StatelessWidget {
  const _TripHeader({required this.view});
  final RouteTripView view;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Material(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${view.trip.vehicleCode} (${view.trip.plateNo})', style: Theme.of(context).textTheme.titleMedium),
              Text(tripStatusLabel(view.status), style: style),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('Cash ${money(view.ledger.cashExpected)}', style: Theme.of(context).textTheme.titleMedium),
            Text('Next no. ${view.series.nextFormatted}', style: style),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- LOADED: count and accept the load

class _LoadedBody extends ConsumerStatefulWidget {
  const _LoadedBody({required this.view});
  final RouteTripView view;

  @override
  ConsumerState<_LoadedBody> createState() => _LoadedBodyState();
}

class _LoadedBodyState extends ConsumerState<_LoadedBody> {
  late final Map<String, TextEditingController> _counts = {
    for (final l in widget.view.trip.lines) l.itemId: TextEditingController(text: qty(l.qtyLoaded))
  };
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _counts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _accept() async {
    final counts = <String, double>{};
    for (final e in _counts.entries) {
      final v = parseNum(e.value.text);
      if (v == null || v < 0) return showError(context, StateError('Enter a count for every item.'));
      counts[e.key] = v;
    }
    setState(() => _busy = true);
    try {
      final issues = await ref.read(routeServiceProvider).acceptLoad(ref.read(authControllerProvider).session!.userId, widget.view.id, counts);
      afterRouteAction(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(issues.isEmpty
              ? 'Load accepted — you are on the road.'
              : 'Load accepted. ${issues.length} item(s) did not match; the branch has been told.')));
    } on ApiException catch (e) {
      if (mounted) {
        showError(context, StateError(e.kind == ApiFailureKind.offline
            ? 'Accepting the load needs a connection (do it at the warehouse).'
            : e.message));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Count the load', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('Check what was put on the truck. Any difference is reported to the branch.'),
        const SizedBox(height: 12),
        for (final l in widget.view.trip.lines)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.itemName),
            subtitle: Text('${l.itemCode} · loaded ${qty(l.qtyLoaded)}'),
            trailing: SizedBox(
              width: 90,
              child: TextField(
                controller: _counts[l.itemId],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.end,
                decoration: const InputDecoration(labelText: 'Counted', isDense: true),
              ),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _accept,
          icon: _busy ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check),
          label: const Text('Accept load and start trip'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- tabs

class _StopsTab extends StatelessWidget {
  const _StopsTab({required this.view});
  final RouteTripView view;

  @override
  Widget build(BuildContext context) {
    final stops = [...view.latest.stops]..sort((a, b) => a.sequence.compareTo(b.sequence));
    if (stops.isEmpty) return const Center(child: Text('No stops on this trip. Use ⋮ → Sale to another customer.'));
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: stops.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = stops[i];
        final open = view.ledger.openOrdersFor(s.customerId);
        final visited = view.ledger.stopVisited(s.customerId);
        final owes = view.ledger.customerOwes(s.customerId);
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: visited && open.isEmpty ? Colors.green : null,
            child: visited && open.isEmpty ? const Icon(Icons.check, color: Colors.white) : Text('${s.sequence}'),
          ),
          title: Text(s.customerName),
          subtitle: Text([
            if (open.isNotEmpty) '${open.length} order(s) to deliver',
            if (owes > 0.004) 'owes ${money(owes)}',
            if ((s.notes ?? '').isNotEmpty) s.notes!,
          ].join(' · ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => StopScreen(tripId: view.id, customerId: s.customerId))),
        );
      },
    );
  }
}

class _StockTab extends StatelessWidget {
  const _StockTab({required this.view});
  final RouteTripView view;

  @override
  Widget build(BuildContext context) {
    final items = view.ledger.items.values.toList()..sort((a, b) => a.code.compareTo(b.code));
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final it = items[i];
        return ListTile(
          title: Text(it.name),
          subtitle: Text('${it.code} · loaded ${qty(it.loaded)} · delivered ${qty(it.delivered)} · sold ${qty(it.vanSold)}'
              '${it.returnedGood + it.returnedDamaged > 0 ? ' · returns ${qty(it.returnedGood + it.returnedDamaged)}' : ''}'),
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(qty(it.onTruck), style: Theme.of(context).textTheme.titleLarge),
            Text('on truck', style: Theme.of(context).textTheme.bodySmall),
          ]),
        );
      },
    );
  }
}

class _ActivityTab extends ConsumerWidget {
  const _ActivityTab({required this.view});
  final RouteTripView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outbox = ref.watch(routeOutboxProvider).valueOrNull ?? const {};
    final events = view.ledger.events.reversed.toList();
    if (events.isEmpty) return const Center(child: Text('Nothing recorded on this trip yet.'));
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: events.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final e = events[i];
        final entry = e.outboxId == null ? null : outbox[e.outboxId];
        return ListTile(
          leading: Icon(_icon(e.kind)),
          title: Text(_title(e)),
          subtitle: Text('${dateTime(e.createdAt)}${entry?.lastError != null && entry!.status != OutboxStatus.synced ? '\n${entry.lastError}' : ''}'),
          isThreeLine: entry?.lastError != null && entry!.status != OutboxStatus.synced,
          trailing: _SyncBadge(entry: entry),
          onTap: e.kind == RouteEventKind.sale || e.kind == RouteEventKind.voidNumber && e.data['total'] != null
              ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => InvoiceScreen(tripId: view.id, eventId: e.id)))
              : null,
        );
      },
    );
  }

  static IconData _icon(String kind) => switch (kind) {
        RouteEventKind.sale => Icons.receipt_long,
        RouteEventKind.voidNumber => Icons.block,
        RouteEventKind.refusal => Icons.do_not_disturb_on_outlined,
        RouteEventKind.customerReturn => Icons.undo,
        RouteEventKind.collection => Icons.payments_outlined,
        _ => Icons.flag,
      };

  static String _title(RouteEvent e) => switch (e.kind) {
        RouteEventKind.sale => '${e.invoiceNumber} · ${e.data['customerName']} · ${money(e.amount('total'))}',
        RouteEventKind.voidNumber => '${e.invoiceNumber} · VOID — ${e.data['voidReason']}',
        RouteEventKind.refusal => 'Not delivered · ${e.data['customerName']}',
        RouteEventKind.customerReturn => 'Return · ${e.data['customerName']}',
        RouteEventKind.collection => 'Collection · ${e.data['customerName']} · ${money(e.amount('amount'))}',
        _ => 'Trip ended · cash ${money(e.amount('cashRemitted'))}',
      };
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.entry});
  final OutboxEntry? entry;

  @override
  Widget build(BuildContext context) {
    final (icon, color, tip) = switch (entry?.status) {
      OutboxStatus.synced => (Icons.cloud_done, Colors.green, 'In ZARI'),
      OutboxStatus.failed => (Icons.error, Colors.red, 'Rejected — see Sync & Queue'),
      OutboxStatus.needsReview => (Icons.help, Colors.orange, 'Needs review — see Sync & Queue'),
      _ => (Icons.cloud_upload_outlined, Colors.grey, 'Waiting to sync'),
    };
    return Tooltip(message: tip, child: Icon(icon, color: color));
  }
}
