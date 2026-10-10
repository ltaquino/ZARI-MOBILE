import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/format.dart';
import '../../shared/sync_widgets.dart';
import '../auth/auth_controller.dart';
import '../auth/session.dart';
import '../inventory/item_list_screen.dart';
import '../inventory/stock_doc_screen.dart';
import '../masterdata/models.dart';
import '../route/ui/route_home_screen.dart';
import '../sales/pos_screen.dart';
import '../sales/sales_order_screen.dart';
import '../sync/outbox.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_screen.dart';

/// Branches the signed-in user may work in — always every id on their
/// profile, named from the offline cache when available (a user without
/// BRANCHES:View can't download the branch list, so fall back to the id).
final userBranchesProvider = FutureProvider<List<({String id, String name, String code})>>((ref) async {
  ref.watch(syncControllerProvider.select((s) => s.lastStockPull));
  final ids = ref.watch(authControllerProvider.select((a) => a.session?.branchIds)) ?? const [];
  final cached = {
    for (final b in await ref.read(masterDataRepositoryProvider).refList(RefEntity.branch, activeOnly: false)) b.id: b
  };
  return [for (final id in ids) (id: id, name: cached[id]?.name ?? id, code: cached[id]?.code ?? '')];
});

/// Today's POS sales rung up on this device (synced or not).
final todaySalesProvider = FutureProvider<({int count, double total})>((ref) async {
  ref.watch(syncControllerProvider.select((s) => s.counts));
  final auth = ref.watch(authControllerProvider);
  final entries = await ref
      .read(outboxRepositoryProvider)
      .list(userId: auth.session?.userId, type: OutboxType.posSale);
  final today = DateTime.now();
  var count = 0;
  var total = 0.0;
  for (final e in entries) {
    final local = e.createdAt.toLocal();
    if (e.branchId != auth.branchId || local.year != today.year || local.month != today.month || local.day != today.day) {
      continue;
    }
    count++;
    total += (e.meta['total'] as num?)?.toDouble() ?? 0;
  }
  return (count: count, total: total);
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final sync = ref.watch(syncControllerProvider);
    final session = auth.session!;
    final branches = ref.watch(userBranchesProvider).valueOrNull ?? const [];
    final branchName = branches.where((b) => b.id == auth.branchId).firstOrNull?.name ?? auth.branchId ?? 'No branch';

    final tiles = <_Tile>[
      if (session.can(Forms.items, FormAction.view))
        _Tile(Icons.inventory_2_outlined, 'Items & Stock', 'Look up items, prices and on-hand',
            (_) => const ItemListScreen()),
      if (session.can(Forms.stockOpnames, FormAction.create))
        _Tile(Icons.fact_check_outlined, 'Stock Count', 'Physical count (stock opname)',
            (_) => const StockDocScreen(mode: StockDocMode.opname)),
      if (session.can(Forms.stockAdjustments, FormAction.create))
        _Tile(Icons.tune, 'Stock Adjustment', 'Correct on-hand with a reason',
            (_) => const StockDocScreen(mode: StockDocMode.adjustment)),
      if (session.can(Forms.routeSales, FormAction.create))
        _Tile(Icons.local_shipping_outlined, 'Truck Route', 'Deliver, sell and collect on your trip',
            (_) => const RouteHomeScreen()),
      if (session.can(Forms.posMode, FormAction.create))
        _Tile(Icons.point_of_sale, 'POS Sale', 'Ring up and take payment', (_) => const PosScreen()),
      if (session.can(Forms.salesOrders, FormAction.create))
        _Tile(Icons.receipt_long_outlined, 'Sales Order', 'Take a customer order', (_) => const SalesOrderScreen()),
      _Tile(Icons.sync, 'Sync & Queue', 'What has and hasn\'t reached ZARI', (_) => const SyncScreen()),
    ];

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: branches.length > 1 ? () => _pickBranch(context, ref, branches, auth.branchId) : null,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(branchName, overflow: TextOverflow.ellipsis)),
            if (branches.length > 1) const Icon(Icons.arrow_drop_down),
          ]),
        ),
        actions: [
          const SyncChip(),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') _logout(context, ref);
            },
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text(session.displayName)),
              const PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(pull: PullMode.quick),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const SessionBanner(),
            if (!sync.hasCatalog) _FirstDownloadCard(sync: sync),
            if (auth.branchId == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Your account has no branch assigned in ZARI. Ask an administrator to assign one.'),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Hello, ${session.firstName.isEmpty ? session.displayName : session.firstName}',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            if (session.can(Forms.posMode, FormAction.create)) _TodayCard(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: GridView.count(
                crossAxisCount: MediaQuery.sizeOf(context).width > 600 ? 3 : 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.25,
                children: [
                  for (final t in tiles)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: auth.branchId == null && t.title != 'Sync & Queue'
                            ? null
                            : () => Navigator.of(context).push(MaterialPageRoute(builder: t.builder)),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(t.icon, color: Theme.of(context).colorScheme.primary, size: 30),
                              const Spacer(),
                              Text(t.title, style: Theme.of(context).textTheme.titleMedium),
                              Text(t.subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Catalog downloaded ${ago(sync.lastItemsPull)} · stock ${ago(sync.lastStockPull)}',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBranch(
      BuildContext context, WidgetRef ref, List<({String id, String name, String code})> branches, String? current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Work in branch')),
          for (final b in branches)
            RadioListTile<String>(
              value: b.id,
              groupValue: current,
              title: Text(b.name),
              subtitle: b.code.isEmpty ? null : Text(b.code),
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
        ]),
      ),
    );
    if (picked != null) await ref.read(authControllerProvider.notifier).setBranch(picked);
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final sync = ref.read(syncControllerProvider);
    final open = sync.pendingCount + sync.attentionCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(open > 0
            ? '$open document(s) have not reached ZARI yet. They stay saved on this device and will sync the next time you sign in.'
            : 'You can sign in again offline on this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) {
      ref.read(syncControllerProvider.notifier).stop();
      await ref.read(authControllerProvider.notifier).logout();
    }
  }
}

class _Tile {
  const _Tile(this.icon, this.title, this.subtitle, this.builder);
  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;
}

class _FirstDownloadCard extends ConsumerWidget {
  const _FirstDownloadCard({required this.sync});
  final SyncState sync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Offline data not downloaded yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(sync.pulling
                ? (sync.pullStage ?? 'Downloading…')
                : 'Items, prices, stock and customers are needed before you can work offline.'),
            const SizedBox(height: 12),
            if (sync.pulling)
              LinearProgressIndicator(value: sync.pullFraction)
            else
              FilledButton.icon(
                onPressed: sync.online ? () => ref.read(syncControllerProvider.notifier).syncNow(pull: PullMode.full) : null,
                icon: const Icon(Icons.download),
                label: Text(sync.online ? 'Download now' : 'Connect to download'),
              ),
          ],
        ),
      ),
    );
  }
}

class _TodayCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(todaySalesProvider).valueOrNull;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.today),
        title: Text(money(today?.total ?? 0)),
        subtitle: Text('${today?.count ?? 0} POS sale(s) today on this device'),
      ),
    );
  }
}
