import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/format.dart';
import '../auth/auth_controller.dart';
import 'outbox.dart';
import 'sync_controller.dart';

final _outboxListProvider = FutureProvider.autoDispose<List<OutboxEntry>>((ref) async {
  ref.watch(syncControllerProvider.select((s) => s.counts));
  final userId = ref.watch(authControllerProvider.select((a) => a.session?.userId));
  final all = await ref.read(outboxRepositoryProvider).list(userId: userId);
  return all.reversed.toList();
});

class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);
    final entries = ref.watch(_outboxListProvider).valueOrNull ?? const [];
    final attention = entries.where((e) => e.status == OutboxStatus.failed || e.status == OutboxStatus.needsReview).toList();
    final waiting = entries.where((e) => e.status == OutboxStatus.pending || e.status == OutboxStatus.syncing).toList();
    final sent = entries.where((e) => e.status == OutboxStatus.synced).toList();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Sync & Queue')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(pull: PullMode.quick),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(sync.online ? Icons.cloud_done_outlined : Icons.cloud_off,
                        color: sync.online ? Colors.green.shade700 : theme.colorScheme.outline),
                    const SizedBox(width: 8),
                    Text(sync.online ? 'Connected to ZARI' : 'Offline', style: theme.textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 8),
                  Text('Catalog: ${ago(sync.lastItemsPull)} · Stock & prices: ${ago(sync.lastStockPull)}'),
                  Text('Last send: ${ago(sync.lastPushAt)} · server: ${ref.read(appConfigProvider).baseUrl}',
                      style: theme.textTheme.bodySmall),
                  if (sync.message != null) ...[
                    const SizedBox(height: 8),
                    Text(sync.message!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  if (sync.skipped.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Not downloaded (no permission): ${sync.skipped.keys.join(', ').replaceAll('_', ' ')}',
                        style: theme.textTheme.bodySmall),
                  ],
                  if (sync.pulling) ...[
                    const SizedBox(height: 12),
                    Text(sync.pullStage ?? ''),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: sync.pullFraction),
                  ],
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(
                      onPressed: sync.busy ? null : () => ref.read(syncControllerProvider.notifier).syncNow(pull: PullMode.quick),
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync now'),
                    ),
                    OutlinedButton.icon(
                      onPressed: sync.busy ? null : () => ref.read(syncControllerProvider.notifier).syncNow(pull: PullMode.full),
                      icon: const Icon(Icons.download),
                      label: const Text('Download all data'),
                    ),
                  ]),
                ]),
              ),
            ),
            _section(context, 'Needs attention', attention, ref, emptyText: null),
            _section(context, 'Waiting to send', waiting, ref, emptyText: 'Nothing waiting.'),
            _section(context, 'Sent to ZARI (last 30 days)', sent, ref, emptyText: 'Nothing sent yet.'),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<OutboxEntry> items, WidgetRef ref, {String? emptyText}) {
    if (items.isEmpty && emptyText == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('$title (${items.length})', style: Theme.of(context).textTheme.titleSmall),
      ),
      if (items.isEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(emptyText!)),
      for (final e in items)
        ListTile(
          leading: _statusIcon(context, e.status),
          title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text([
            e.serverRef ?? e.localRef,
            dateTime(e.createdAt),
            if (e.status == OutboxStatus.failed || e.status == OutboxStatus.needsReview) e.lastError ?? '',
          ].where((s) => s.isNotEmpty).join(' · '), maxLines: 3, overflow: TextOverflow.ellipsis),
          onTap: () => _showEntry(context, ref, e),
        ),
    ]);
  }

  Widget _statusIcon(BuildContext context, OutboxStatus s) {
    final scheme = Theme.of(context).colorScheme;
    return switch (s) {
      OutboxStatus.synced => Icon(Icons.check_circle, color: Colors.green.shade700),
      OutboxStatus.failed => Icon(Icons.error, color: scheme.error),
      OutboxStatus.needsReview => Icon(Icons.help, color: scheme.tertiary),
      OutboxStatus.syncing => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
      OutboxStatus.pending => Icon(Icons.schedule, color: scheme.outline),
    };
  }

  Future<void> _showEntry(BuildContext context, WidgetRef ref, OutboxEntry e) async {
    final repo = ref.read(outboxRepositoryProvider);
    final sync = ref.read(syncControllerProvider.notifier);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Text(OutboxType.label(e.type), style: Theme.of(ctx).textTheme.titleLarge),
            Text(e.title),
            const SizedBox(height: 8),
            Text('Mobile ref: ${e.localRef}'),
            if (e.serverRef != null) Text('ZARI no.: ${e.serverRef}'),
            Text('Created ${dateTime(e.createdAt)} · attempts ${e.attempts}'),
            if (e.syncedAt != null) Text('Synced ${dateTime(e.syncedAt!)}'),
            if (e.lastError != null) ...[
              const SizedBox(height: 8),
              Text(e.lastError!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ],
            if (e.status == OutboxStatus.needsReview) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(e.type == OutboxType.posSale
                      ? 'The phone lost its connection while sending this sale. Before retrying, check ZARI web '
                          '(Sales › Sales Invoices, terminal ${e.meta['terminalCode']}, around ${dateTime(e.createdAt)}, total '
                          '${money(e.meta['total'] as num?)}). If it is there, mark it as synced; retrying would record it twice.'
                      : 'The phone lost its connection while sending this. Search ZARI web for "${e.localRef}" in the '
                          'remarks. If it exists, mark it as synced; otherwise retry.'),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (e.status == OutboxStatus.failed || e.status == OutboxStatus.needsReview)
                FilledButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: Text(e.status == OutboxStatus.needsReview ? 'Not in ZARI — retry' : 'Retry'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await sync.retry(e);
                  },
                ),
              if (e.status == OutboxStatus.needsReview)
                OutlinedButton.icon(
                  icon: const Icon(Icons.done_all),
                  label: const Text('Found in ZARI — mark synced'),
                  onPressed: () async {
                    final no = await _askText(ctx, 'ZARI document no. (optional)');
                    await repo.resolveManually(e.id, serverRef: no);
                    if (ctx.mounted) Navigator.pop(ctx);
                    await sync.refreshLocal();
                  },
                ),
              if (e.type == OutboxType.routeSale && e.status == OutboxStatus.failed)
                OutlinedButton.icon(
                  icon: const Icon(Icons.block),
                  label: const Text('Void this invoice number'),
                  onPressed: () async {
                    final reason = await _askText(ctx, 'Why is it voided? (e.g. rejected by ZARI: ...)');
                    if (reason == null || reason.trim().isEmpty) return;
                    try {
                      await ref.read(routeServiceProvider).voidRejectedSale(e, reason.trim());
                      if (ctx.mounted) Navigator.pop(ctx);
                      await sync.kick();
                    } catch (err) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(err is StateError ? err.message : '$err')));
                      }
                    }
                  },
                ),
              if (e.isOpen && e.serverId == null && e.type != OutboxType.routeSale && e.type != OutboxType.routeVoid)
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Discard'),
                  style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (d) => AlertDialog(
                        title: const Text('Discard permanently?'),
                        content: Text(e.type == OutboxType.posSale
                            ? 'This sale was paid for at the counter. Discarding means it will never be recorded in ZARI.'
                            : 'This will never be sent to ZARI.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep')),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Discard')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    if (OutboxType.isRoute(e.type)) {
                      await ref.read(routeServiceProvider).discardRouteEntry(e);
                    } else {
                      await repo.discard(e.id);
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                    await sync.refreshLocal();
                  },
                ),
            ]),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Technical details'),
              children: [
                SelectableText('${e.method} ${e.path}\n${const JsonEncoder.withIndent('  ').convert(e.body)}'
                    '${e.serverResponse == null ? '' : '\n\nResponse:\n${const JsonEncoder.withIndent('  ').convert(e.serverResponse)}'}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askText(BuildContext context, String label) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(labelText: label)),
        actions: [FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('OK'))],
      ),
    );
  }
}
