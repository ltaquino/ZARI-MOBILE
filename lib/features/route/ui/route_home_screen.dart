import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/format.dart';
import '../../../shared/sync_widgets.dart';
import '../../sync/sync_controller.dart';
import '../route_models.dart';
import 'printer_setup_screen.dart';
import 'route_providers.dart';
import 'trip_screen.dart';

String tripStatusLabel(String status) => switch (status) {
      TripStatus.loaded => 'Loaded — count the load',
      TripStatus.inTransit => 'On the road',
      TripStatus.pendingClose => 'Ended — waiting for close',
      _ => status,
    };

/// The driver's trips (assigned in ZARI web, loaded at the warehouse). Works offline from the last download.
class RouteHomeScreen extends ConsumerWidget {
  const RouteHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trips = ref.watch(routeTripsProvider);
    final sync = ref.watch(syncControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Trips'),
        actions: [
          const SyncChip(),
          IconButton(
            tooltip: 'Printer',
            icon: const Icon(Icons.print_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrinterSetupScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(pull: PullMode.quick),
        child: trips.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('$e'))]),
          data: (list) => ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(children: [
                    const Icon(Icons.local_shipping_outlined, size: 64),
                    const SizedBox(height: 12),
                    Text('No trip on the road for you.', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      sync.online
                          ? 'Once the branch approves your load-out, pull down to download it.'
                          : 'Connect to download your trip.',
                      textAlign: TextAlign.center,
                    ),
                  ]),
                ),
              for (final t in list)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.local_shipping, size: 36),
                    title: Text('${t.trip.tripNo} · ${t.trip.vehicleCode}'),
                    subtitle: Text('${tripStatusLabel(t.status)}\n'
                        '${t.ledger.invoiceCount} invoice(s) · cash ${money(t.ledger.cashExpected)} · '
                        'next ${t.series.nextFormatted}'),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripScreen(tripId: t.id))),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Trips downloaded ${ago(sync.lastTripsPull)}',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
