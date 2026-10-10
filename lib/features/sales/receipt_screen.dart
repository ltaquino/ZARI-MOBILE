import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/format.dart';
import '../sync/outbox.dart';
import '../sync/sync_controller.dart';

final _entryProvider = FutureProvider.autoDispose.family<OutboxEntry?, String>((ref, id) {
  ref.watch(syncControllerProvider.select((s) => s.counts));
  return ref.read(outboxRepositoryProvider).get(id);
});

/// On-screen receipt for a POS sale. Until ZARI confirms the sale it is
/// explicitly provisional: the official invoice / BIR OR number only exists
/// once ZARI has posted it.
class ReceiptScreen extends ConsumerWidget {
  const ReceiptScreen({super.key, required this.entryId});

  final String entryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(_entryProvider(entryId)).valueOrNull;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: entry == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatusCard(entry: entry),
                const SizedBox(height: 16),
                Text('${entry.meta['customerName']}', style: theme.textTheme.titleMedium),
                Text('Terminal ${entry.meta['terminalCode']} · ${dateTime(DateTime.parse(entry.meta['soldAt'] as String))}'),
                Text('Ref ${entry.localRef}', style: theme.textTheme.bodySmall),
                const Divider(height: 24),
                for (final l in (entry.meta['lines'] as List).cast<Map<String, dynamic>>())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Text('${l['name']}\n${qty(l['qty'] as num)} × ${money(l['unitPrice'] as num)}'
                            '${l['statutory'] == true ? '  (statutory disc.)' : ''}'),
                      ),
                      Text(money(l['net'] as num)),
                    ]),
                  ),
                const Divider(height: 24),
                _row('VATable sales', entry.meta['vatableSales']),
                _row('VAT-exempt sales', entry.meta['vatExemptSales']),
                _row('Zero-rated sales', entry.meta['zeroRatedSales']),
                _row('VAT (12%)', entry.meta['vat']),
                if (((entry.meta['discount'] as num?) ?? 0) > 0) _row('Discount', entry.meta['discount']),
                const SizedBox(height: 8),
                _row('TOTAL', entry.meta['total'], bold: true, theme: theme),
                const Divider(height: 24),
                for (final t in (entry.meta['tenders'] as List).cast<Map<String, dynamic>>()) _row('${t['method']}', t['amount']),
                _row('Change', entry.serverResponse?['changeDue'] ?? entry.meta['change'], bold: true, theme: theme),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('New sale'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
              ],
            ),
    );
  }

  Widget _row(String label, Object? value, {bool bold = false, ThemeData? theme}) {
    final style = bold ? theme?.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Text(label, style: style),
        const Spacer(),
        Text(money(value as num?), style: style),
      ]),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.entry});
  final OutboxEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final birNo = entry.serverResponse?['birOrSeriesNumber'] as String?;
    final (color, icon, title, body) = switch (entry.status) {
      OutboxStatus.synced => (
          Colors.green.shade50,
          Icons.verified_outlined,
          'Posted in ZARI · ${entry.serverRef ?? ''}',
          birNo == null ? 'Sale and payment recorded.' : 'BIR OR / series no. $birNo',
        ),
      OutboxStatus.failed => (
          scheme.errorContainer,
          Icons.error_outline,
          'ZARI rejected this sale',
          '${entry.lastError ?? ''}\nOpen Sync & Queue to review it.',
        ),
      OutboxStatus.needsReview => (
          scheme.tertiaryContainer,
          Icons.help_outline,
          'Needs review',
          '${entry.lastError ?? ''}\nCheck ZARI before retrying, so it isn\'t recorded twice.',
        ),
      _ => (
          scheme.secondaryContainer,
          Icons.schedule,
          'Saved on this device — waiting to sync',
          'PROVISIONAL: not an official receipt. The invoice / BIR OR number is assigned when ZARI receives it.',
        ),
    };
    return Card(
      color: color,
      child: ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(body)),
    );
  }
}
