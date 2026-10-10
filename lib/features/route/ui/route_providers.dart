import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../auth/auth_controller.dart';
import '../../sync/sync_controller.dart';
import '../route_service.dart';

/// Bumped after every action recorded on the device, so open screens re-read the ledger.
final routeTickProvider = StateProvider<int>((_) => 0);

final routeTripsProvider = FutureProvider<List<RouteTripView>>((ref) async {
  ref.watch(routeTickProvider);
  ref.watch(syncControllerProvider.select((s) => s.lastTripsPull));
  ref.watch(syncControllerProvider.select((s) => s.counts));
  final userId = ref.watch(authControllerProvider.select((a) => a.session?.userId));
  if (userId == null) return const [];
  return ref.read(routeServiceProvider).trips(userId);
});

final routeTripProvider = FutureProvider.family<RouteTripView?, String>((ref, tripId) async {
  ref.watch(routeTickProvider);
  ref.watch(syncControllerProvider.select((s) => s.lastTripsPull));
  ref.watch(syncControllerProvider.select((s) => s.counts));
  return ref.read(routeServiceProvider).trip(tripId);
});

/// After recording something: refresh the screens and push it now if there's a connection.
void afterRouteAction(WidgetRef ref) {
  ref.read(routeTickProvider.notifier).state++;
  ref.read(syncControllerProvider.notifier).kick();
}

void showError(BuildContext context, Object error) {
  final message = error is StateError ? error.message : '$error';
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Not recorded'),
      content: Text(message),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}
