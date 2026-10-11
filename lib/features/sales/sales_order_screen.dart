import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/format.dart';
import '../../shared/item_picker.dart';
import '../auth/auth_controller.dart';
import '../masterdata/models.dart';
import '../sync/sync_controller.dart';
import 'customer_picker.dart';
import 'line_editor.dart';
import 'sales_calculator.dart';
import 'sales_order_service.dart';

class SalesOrderScreen extends ConsumerStatefulWidget {
  const SalesOrderScreen({super.key});

  @override
  ConsumerState<SalesOrderScreen> createState() => _SalesOrderScreenState();
}

class _SalesOrderScreenState extends ConsumerState<SalesOrderScreen> {
  RefRecord? _customer;
  DateTime _orderDate = DateTime.now();
  DateTime? _deliveryDate;
  final _remarks = TextEditingController();
  final List<CartLine> _lines = [];
  double _headerDiscountPct = 0;
  bool _submit = true;
  bool _saving = false;
  int _seq = 0;

  String get _branchId => ref.read(authControllerProvider).branchId!;

  @override
  void dispose() {
    _remarks.dispose();
    super.dispose();
  }

  Future<void> _pickCustomer() async {
    final c = await CustomerPickerScreen.pick(context);
    if (c == null) return;
    setState(() {
      _customer = c;
      // Discount Scheme: the customer's standing % is suggested on every line, always overridable.
      final standing = c.numField('standingDiscountPct');
      for (final l in _lines) {
        if (l.discountPct == 0) l.discountPct = standing;
      }
    });
  }

  Future<void> _addItem() async {
    final entry = await ItemPickerScreen.pick(context, branchId: _branchId, title: 'Add to order');
    if (entry == null || !mounted) return;
    if (!entry.item.isSold || !entry.item.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${entry.item.code} is not an active sellable item.')));
      return;
    }
    final line = CartLine(
      key: 's${_seq++}',
      item: entry.item,
      qty: entry.packQty,
      unitPrice: entry.price ?? 0,
      discountPct: _customer?.numField('standingDiscountPct') ?? 0,
    );
    setState(() => _lines.add(line));
    await _editLine(line);
  }

  Future<void> _editLine(CartLine line) async {
    final r = await editSalesLine(context, line);
    if (r == false) setState(() => _lines.remove(line));
    if (r == true) setState(() {});
  }

  Future<DateTime?> _date(DateTime? initial, {required DateTime first}) => showDatePicker(
        context: context,
        initialDate: initial ?? DateTime.now(),
        firstDate: first,
        lastDate: DateTime.now().add(const Duration(days: 365)),
      );

  Future<void> _save() async {
    if (_customer == null || _lines.isEmpty) return;
    setState(() => _saving = true);
    final auth = ref.read(authControllerProvider);
    try {
      final entry = await queueSalesOrder(
        outbox: ref.read(outboxRepositoryProvider),
        userId: auth.session!.userId,
        branchId: auth.branchId!,
        customer: _customer!,
        orderDate: _orderDate,
        expectedDeliveryDate: _deliveryDate,
        remarks: _remarks.text,
        headerDiscountPct: _headerDiscountPct,
        lines: _lines,
        submitForApproval: _submit,
      );
      await ref.read(syncControllerProvider.notifier).kick();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Order saved as ${entry.localRef}.')));
      Navigator.of(context).pop();
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final totals = CartTotals.of(_lines, headerDiscountPct: _headerDiscountPct);
    final theme = Theme.of(context);
    return PopScope(
      canPop: _lines.isEmpty || _saving,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(title: const Text('Discard this order?'), actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
          ]),
        );
        if (ok == true && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('New Sales Order')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _addItem,
          icon: const Icon(Icons.add),
          label: const Text('Add item'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(_customer?.name ?? 'Choose customer'),
                subtitle: _customer == null ? const Text('Required') : null,
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickCustomer,
              ),
            ),
            Row(children: [
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Order date'),
                  subtitle: Text(date(_orderDate)),
                  onTap: () async {
                    final d = await _date(_orderDate, first: DateTime.now().subtract(const Duration(days: 30)));
                    if (d != null) setState(() => _orderDate = d);
                  },
                ),
              ),
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Expected delivery'),
                  subtitle: Text(_deliveryDate == null ? 'Not set' : date(_deliveryDate!)),
                  onTap: () async {
                    final d = await _date(_deliveryDate, first: _orderDate);
                    setState(() => _deliveryDate = d);
                  },
                ),
              ),
            ]),
            TextField(controller: _remarks, maxLength: 280, decoration: const InputDecoration(labelText: 'Remarks')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _submit,
              onChanged: (v) => setState(() => _submit = v),
              title: const Text('Submit for approval after saving'),
              subtitle: const Text('Off = saved as DRAFT in ZARI'),
            ),
            const Divider(),
            for (final l in _lines)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.item.name),
                subtitle: Text('${qty(l.qty)} × ${money(l.unitPrice)}${l.discountPct > 0 ? ' · ${qty(l.discountPct)}% off' : ''}'),
                trailing: Text(money(l.calc.net), style: theme.textTheme.titleSmall),
                onTap: () => _editLine(l),
              ),
            if (_lines.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No items yet.'))),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Order discount'),
              trailing: SizedBox(
                width: 90,
                child: TextField(
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(suffixText: '%', isDense: true),
                  onChanged: (v) => setState(() => _headerDiscountPct = (parseNum(v) ?? 0).clamp(0, 100).toDouble()),
                ),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Total', style: theme.textTheme.titleMedium),
              subtitle: Text('incl. VAT ${money(totals.vat)}'),
              trailing: Text(money(totals.total), style: theme.textTheme.headlineSmall),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving || _customer == null || _lines.isEmpty ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(_saving ? 'Saving…' : 'Save order'),
            ),
          ],
        ),
      ),
    );
  }
}
