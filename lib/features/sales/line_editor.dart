import 'package:flutter/material.dart';

import '../../shared/format.dart';
import '../masterdata/models.dart';
import 'sales_calculator.dart';

/// Bottom sheet to edit one cart/order line. Returns true when the line
/// was changed, `null` when dismissed, false when the user removed it.
Future<bool?> editSalesLine(
  BuildContext context,
  CartLine line, {
  List<RefRecord> statutoryTypes = const [],
  bool allowStatutory = false,
  bool allowSerial = false,
}) {
  final qtyCtl = TextEditingController(text: qty(line.qty));
  final priceCtl = TextEditingController(text: line.unitPrice.toStringAsFixed(2));
  final discCtl = TextEditingController(text: line.discountPct == 0 ? '' : qty(line.discountPct));
  final idCtl = TextEditingController(text: line.statutoryIdNumber ?? '');
  final serialCtl = TextEditingController(text: line.serialNo ?? '');
  String? statutoryId = line.statutoryDiscountTypeId;
  String? error;

  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final selected = statutoryTypes.where((s) => s.id == statutoryId).firstOrNull;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(ctx).bottom + 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(line.item.name, style: Theme.of(ctx).textTheme.titleMedium),
                Text(line.item.code),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: qtyCtl,
                      enabled: !line.item.isSerialized,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Qty'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: priceCtl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Unit price'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: discCtl,
                      enabled: statutoryId == null,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Disc. %'),
                    ),
                  ),
                ]),
                if (allowSerial && line.item.isSerialized)
                  TextField(controller: serialCtl, decoration: const InputDecoration(labelText: 'Serial no.')),
                if (allowStatutory && statutoryTypes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    value: statutoryId,
                    decoration: const InputDecoration(labelText: 'Statutory discount (Senior / PWD / …)'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('None')),
                      for (final s in statutoryTypes)
                        DropdownMenuItem<String?>(value: s.id, child: Text('${s.name} (${qty(s.numField('discountPct'))}%)')),
                    ],
                    onChanged: (v) => setState(() => statutoryId = v),
                  ),
                  if (selected != null)
                    TextField(
                      controller: idCtl,
                      decoration: InputDecoration(labelText: selected.strField('requiredIdLabel') ?? 'ID number'),
                    ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ],
                const SizedBox(height: 16),
                Row(children: [
                  TextButton.icon(
                    onPressed: () => Navigator.pop(ctx, false),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                    style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      final q = parseNum(qtyCtl.text);
                      final p = parseNum(priceCtl.text);
                      final d = discCtl.text.trim().isEmpty ? 0.0 : parseNum(discCtl.text);
                      if (q == null || q <= 0 || p == null || p < 0 || d == null || d < 0 || d > 100) {
                        setState(() => error = 'Check qty (> 0), price (≥ 0) and discount (0–100).');
                        return;
                      }
                      line
                        ..qty = q
                        ..unitPrice = p
                        ..discountPct = selected == null ? d : 0
                        ..statutoryDiscountTypeId = selected?.id
                        ..statutoryDiscountPct = selected?.numField('discountPct')
                        ..statutoryIdNumber = selected == null ? null : idCtl.text.trim()
                        ..serialNo = serialCtl.text.trim().isEmpty ? null : serialCtl.text.trim();
                      Navigator.pop(ctx, true);
                    },
                    child: const Text('Apply'),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    ),
  );
}
