import 'package:flutter/material.dart';

import '../../shared/format.dart';
import '../masterdata/models.dart';
import 'pos_service.dart';
import 'sales_calculator.dart';

/// Payment step: one or more tenders (split payment), change computed the
/// same way CreatePosSaleCommandHandler does it.
class PosCheckoutSheet extends StatefulWidget {
  const PosCheckoutSheet({super.key, required this.total, required this.methods});

  final double total;
  final List<RefRecord> methods;

  static Future<List<Tender>?> show(BuildContext context, {required double total, required List<RefRecord> methods}) =>
      showModalBottomSheet<List<Tender>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => PosCheckoutSheet(total: total, methods: methods),
      );

  @override
  State<PosCheckoutSheet> createState() => _PosCheckoutSheetState();
}

class _PosCheckoutSheetState extends State<PosCheckoutSheet> {
  final List<Tender> _tenders = [];
  final Map<Tender, TextEditingController> _amountCtl = {};
  List<String> _problems = [];

  @override
  void initState() {
    super.initState();
    final cash = widget.methods.where((m) => m.code.toUpperCase() == 'CASH').firstOrNull ?? widget.methods.firstOrNull;
    if (cash != null) _add(cash, widget.total);
  }

  @override
  void dispose() {
    for (final c in _amountCtl.values) {
      c.dispose();
    }
    super.dispose();
  }

  double get _tendered => round4(_tenders.fold(0.0, (s, t) => s + t.amount));
  double get _remaining => round4(widget.total - _tendered);

  void _add(RefRecord method, double amount) {
    final t = Tender(method: method, amount: amount);
    _tenders.add(t);
    _amountCtl[t] = TextEditingController(text: amount == 0 ? '' : amount.toStringAsFixed(2));
  }

  void _setAmount(Tender t, double v) {
    t.amount = v;
    _amountCtl[t]!.text = v.toStringAsFixed(2);
    setState(() => _problems = []);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = -_remaining;
    final quickCash = <double>{
      widget.total,
      for (final step in [20.0, 50.0, 100.0, 500.0, 1000.0]) (widget.total / step).ceilToDouble() * step,
    }.toList()
      ..sort();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Total due', style: theme.textTheme.titleSmall),
            Text(money(widget.total), style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            for (final t in _tenders) ...[
              Row(children: [
                Expanded(child: Text(t.method.name, style: theme.textTheme.titleMedium)),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _amountCtl[t],
                    textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(prefixText: '₱ ', isDense: true),
                    onChanged: (v) => setState(() {
                      t.amount = parseNum(v) ?? 0;
                      _problems = [];
                    }),
                  ),
                ),
                if (_tenders.length > 1)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _tenders.remove(t);
                      _amountCtl.remove(t)?.dispose();
                    }),
                  ),
              ]),
              if (t.isCash)
                Wrap(spacing: 8, children: [
                  for (final v in quickCash)
                    ActionChip(label: Text(v == widget.total ? 'Exact' : money(v)), onPressed: () => _setAmount(t, v)),
                ]),
              if (t.method.boolField('requiresReferenceNo'))
                TextField(
                  decoration: InputDecoration(labelText: t.method.strField('referenceNoLabel') ?? 'Reference no.', isDense: true),
                  onChanged: (v) => t.referenceNo = v,
                ),
              if (t.method.boolField('requiresBankOrPartnerName'))
                TextField(
                  decoration: const InputDecoration(labelText: 'Bank / partner', isDense: true),
                  onChanged: (v) => t.bankOrPartnerName = v,
                ),
              const SizedBox(height: 12),
            ],
            Wrap(spacing: 8, children: [
              for (final m in widget.methods.where((m) => !_tenders.any((t) => t.method.id == m.id)))
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(m.name),
                  // A non-cash tender must match the remaining balance exactly (4 dp).
                  onPressed: () => setState(() => _add(m, _remaining > 0 ? _remaining : 0)),
                ),
            ]),
            const Divider(height: 32),
            Row(children: [
              Text(change > 0 ? 'Change' : 'Remaining', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(money(change > 0 ? change : _remaining),
                  style: theme.textTheme.headlineSmall?.copyWith(
                      color: change >= 0 ? Colors.green.shade700 : theme.colorScheme.error, fontWeight: FontWeight.w600)),
            ]),
            if (_problems.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final p in _problems) Text('• $p', style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () {
                final problems = validateTenders(_tenders, widget.total);
                if (problems.isNotEmpty) {
                  setState(() => _problems = problems);
                  return;
                }
                Navigator.pop(context, _tenders);
              },
              child: const Text('Complete sale', style: TextStyle(fontSize: 18)),
            ),
          ],
        ),
      ),
    );
  }
}
