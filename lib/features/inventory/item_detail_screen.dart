import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/format.dart';
import '../auth/auth_controller.dart';
import '../masterdata/master_data_repository.dart';
import '../masterdata/models.dart';
import '../sync/sync_controller.dart';

class _ItemDetail {
  const _ItemDetail(this.entry, this.balances, this.warehouseNames, this.uom, this.pendingPos);
  final ItemEntry entry;
  final List<StockBalance> balances;
  final Map<String, String> warehouseNames;
  final String uom;
  final double pendingPos;
}

final _itemDetailProvider = FutureProvider.autoDispose.family<_ItemDetail?, String>((ref, itemId) async {
  ref.watch(syncControllerProvider.select((s) => s.lastStockPull));
  final branchId = ref.watch(authControllerProvider.select((a) => a.branchId))!;
  final repo = ref.read(masterDataRepositoryProvider);
  final entry = await repo.itemEntry(itemId, branchId: branchId);
  if (entry == null) return null;
  final warehouses = await repo.refList(RefEntity.warehouse, activeOnly: false);
  final uom = await repo.ref(RefEntity.uom, entry.item.baseUomId);
  return _ItemDetail(
    entry,
    await repo.balancesForItem(itemId, branchId: branchId),
    {for (final w in warehouses) w.id: w.name},
    uom?.code ?? '',
    await repo.pendingPosQty(itemId, branchId),
  );
});

class ItemDetailScreen extends ConsumerWidget {
  const ItemDetailScreen({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(_itemDetailProvider(itemId));
    final stockPulled = ref.watch(syncControllerProvider.select((s) => s.lastStockPull));
    return Scaffold(
      appBar: AppBar(title: const Text('Item')),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (d) {
          if (d == null) return const Center(child: Text('Item not found in the offline catalog.'));
          final item = d.entry.item;
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(item.name, style: theme.textTheme.headlineSmall),
              Text('${item.code}${d.uom.isEmpty ? '' : ' · ${d.uom}'}', style: theme.textTheme.bodyMedium),
              if (item.description?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(item.description!),
              ],
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _chip(context, item.isActive ? 'Active' : 'Inactive'),
                _chip(context, vatTypeCode(item.vatType).replaceAll('_', ' ')),
                if (item.isSerialized) _chip(context, 'Serialized'),
                if (item.isBatchTracked) _chip(context, 'Batch tracked'),
                if (item.allowNegativeStock) _chip(context, 'Negative stock allowed'),
              ]),
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  title: const Text('Selling price at this branch'),
                  trailing: Text(money(d.entry.price), style: theme.textTheme.titleLarge),
                  subtitle: d.entry.posBlockReason == null ? null : Text(d.entry.posBlockReason!),
                ),
              ),
              if (item.isStocked) ...[
                const SizedBox(height: 16),
                Text('Stock on hand', style: theme.textTheme.titleMedium),
                Text('As downloaded ${ago(stockPulled)}', style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Card(
                  child: Column(children: [
                    if (d.balances.isEmpty) const ListTile(title: Text('No stock recorded at this branch.')),
                    for (final b in d.balances)
                      ListTile(
                        dense: true,
                        title: Text(d.warehouseNames[b.warehouseId] ?? b.warehouseId),
                        subtitle: Text([
                          if (b.batchNo?.isNotEmpty == true) 'Batch ${b.batchNo}',
                          'Avg cost ${money(b.avgUnitCost)}',
                        ].join(' · ')),
                        trailing: Text(qty(b.qtyOnHand), style: theme.textTheme.titleMedium),
                      ),
                    const Divider(height: 1),
                    ListTile(
                      title: const Text('Branch total'),
                      trailing: Text(qty(d.entry.onHand), style: theme.textTheme.titleMedium),
                    ),
                    if (d.pendingPos > 0)
                      ListTile(
                        title: const Text('Sold on this device, not yet synced'),
                        subtitle: Text('Available ≈ ${qty(d.entry.onHand - d.pendingPos)}'),
                        trailing: Text('−${qty(d.pendingPos)}',
                            style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.error)),
                      ),
                  ]),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _chip(BuildContext context, String label) =>
      Chip(label: Text(label), visualDensity: VisualDensity.compact);
}
