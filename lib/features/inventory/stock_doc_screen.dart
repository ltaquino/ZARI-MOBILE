import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/format.dart';
import '../../shared/item_picker.dart';
import '../auth/auth_controller.dart';
import '../masterdata/models.dart';
import '../sync/sync_controller.dart';
import 'stock_documents.dart';

export 'stock_documents.dart' show StockDocMode;

/// Stock Count (opname) and Stock Adjustment share one screen: pick a
/// warehouse, scan/search items, enter the counted (or corrected) quantity.
/// Saved to the outbox and sent to ZARI when online.
class StockDocScreen extends ConsumerStatefulWidget {
  const StockDocScreen({super.key, required this.mode});

  final StockDocMode mode;

  @override
  ConsumerState<StockDocScreen> createState() => _StockDocScreenState();
}

class _StockDocScreenState extends ConsumerState<StockDocScreen> {
  List<RefRecord> _warehouses = [];
  List<RefRecord> _reasons = [];
  String? _warehouseId;
  String? _reasonCode;
  final _remarks = TextEditingController();
  final List<StockDocLine> _lines = [];
  bool _submitForApproval = true;
  bool _saving = false;

  bool get _isOpname => widget.mode == StockDocMode.opname;
  String get _branchId => ref.read(authControllerProvider).branchId!;

  @override
  void initState() {
    super.initState();
    _loadRefs();
  }

  @override
  void dispose() {
    _remarks.dispose();
    super.dispose();
  }

  Future<void> _loadRefs() async {
    final repo = ref.read(masterDataRepositoryProvider);
    final warehouses = await repo.refList(RefEntity.warehouse, branchId: _branchId);
    final reasons = _isOpname ? <RefRecord>[] : await repo.refList(RefEntity.adjustmentReason);
    if (!mounted) return;
    setState(() {
      _warehouses = warehouses;
      _reasons = reasons;
      _warehouseId ??= warehouses.length == 1 ? warehouses.first.id : null;
    });
  }

  Future<void> _addItem() async {
    if (_warehouseId == null) {
      _snack('Choose a warehouse first.');
      return;
    }
    final entry = await ItemPickerScreen.pick(context, branchId: _branchId, title: 'Add item to count');
    if (entry == null || !mounted) return;
    if (!entry.item.isStocked) {
      _snack('${entry.item.code} is not a stocked item.');
      return;
    }
    final existing = _lines.where((l) => l.item.id == entry.item.id && !entry.item.isBatchTracked && !entry.item.isSerialized);
    if (existing.isNotEmpty) {
      // Scanning the same item again counts one more unit.
      setState(() => existing.first.countedQty += 1);
      _snack('${entry.item.code}: counted ${qty(existing.first.countedQty)}');
      return;
    }
    final bal = await ref.read(masterDataRepositoryProvider).balanceAt(entry.item.id, _warehouseId!);
    final system = bal.qty < 0 ? 0.0 : bal.qty;
    setState(() => _lines.insert(
        0,
        StockDocLine(
          item: entry.item,
          systemQty: system,
          unitCost: bal.avgCost,
          countedQty: _isOpname ? 0 : system,
        )));
    if (mounted) await _editLine(_lines.first);
  }

  Future<void> _editLine(StockDocLine line) async {
    final qtyCtl = TextEditingController(text: qty(line.countedQty));
    final batchCtl = TextEditingController(text: line.batchNo ?? '');
    final serialCtl = TextEditingController(text: line.serialNo ?? '');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(ctx).bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(line.item.name, style: Theme.of(ctx).textTheme.titleMedium),
            Text('${line.item.code} · System qty ${qty(line.systemQty)}'),
            const SizedBox(height: 12),
            TextField(
              controller: qtyCtl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: _isOpname ? 'Counted qty' : 'Correct qty (after)'),
              onTap: () => qtyCtl.selection = TextSelection(baseOffset: 0, extentOffset: qtyCtl.text.length),
            ),
            if (line.item.isBatchTracked)
              TextField(controller: batchCtl, decoration: const InputDecoration(labelText: 'Batch no.')),
            if (line.item.isSerialized)
              TextField(controller: serialCtl, decoration: const InputDecoration(labelText: 'Serial no.')),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final v = parseNum(qtyCtl.text);
    if (v == null || v < 0) {
      _snack('Enter a quantity of 0 or more.');
      return;
    }
    setState(() {
      line.countedQty = v;
      line.batchNo = batchCtl.text;
      line.serialNo = serialCtl.text;
    });
  }

  Future<void> _changeWarehouse(String? id) async {
    if (id == _warehouseId) return;
    if (_lines.isNotEmpty) {
      final ok = await _confirm('Change warehouse?', 'System quantities are per warehouse, so the current lines will be cleared.');
      if (!ok) return;
    }
    setState(() {
      _warehouseId = id;
      _lines.clear();
    });
  }

  Future<void> _save() async {
    final auth = ref.read(authControllerProvider);
    if (_warehouseId == null || _lines.isEmpty) return;
    if (!_isOpname && !_lines.any((l) => l.variance != 0)) {
      _snack('Nothing to adjust — every line matches the system quantity.');
      return;
    }
    if (_lines.any((l) => l.item.isSerialized && (l.serialNo ?? '').trim().isEmpty)) {
      _snack('Enter the serial no. for every serialized item.');
      return;
    }
    setState(() => _saving = true);
    try {
      final entry = await queueStockDocument(
        outbox: ref.read(outboxRepositoryProvider),
        mode: widget.mode,
        userId: auth.session!.userId,
        branchId: auth.branchId!,
        warehouseId: _warehouseId!,
        warehouseName: _warehouses.firstWhere((w) => w.id == _warehouseId).name,
        date: DateTime.now(),
        lines: _lines,
        reasonCode: _reasonCode,
        remarks: _remarks.text,
        submitForApproval: !_isOpname && _submitForApproval,
      );
      await ref.read(syncControllerProvider.notifier).kick();
      if (!mounted) return;
      _snack('Saved as ${entry.localRef}. It will be sent to ZARI ${ref.read(syncControllerProvider).online ? 'now' : 'when online'}.');
      Navigator.of(context).pop();
    } catch (e) {
      _snack('$e');
      setState(() => _saving = false);
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(title: Text(title), content: Text(body), actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ]),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final stockPulled = ref.watch(syncControllerProvider.select((s) => s.lastStockPull));
    final variances = _lines.where((l) => l.variance != 0).length;
    return PopScope(
      canPop: _lines.isEmpty || _saving,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        if (await _confirm('Discard this ${_isOpname ? 'count' : 'adjustment'}?', 'The lines you entered will be lost.') &&
            mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_isOpname ? 'Stock Count' : 'Stock Adjustment')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _addItem,
          icon: const Icon(Icons.add),
          label: const Text('Add / scan item'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            DropdownButtonFormField<String>(
              value: _warehouseId,
              decoration: const InputDecoration(labelText: 'Warehouse'),
              items: [for (final w in _warehouses) DropdownMenuItem(value: w.id, child: Text(w.name))],
              onChanged: _changeWarehouse,
            ),
            if (_warehouses.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No warehouses downloaded for this branch yet.'),
              ),
            if (!_isOpname) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _reasonCode,
                decoration: const InputDecoration(labelText: 'Reason'),
                items: [
                  for (final r in _reasons)
                    DropdownMenuItem(value: r.code, child: Text('${r.code} — ${r.strField('description') ?? ''}')),
                ],
                onChanged: (v) => setState(() => _reasonCode = v),
              ),
            ],
            const SizedBox(height: 12),
            TextField(controller: _remarks, maxLength: 280, decoration: const InputDecoration(labelText: 'Remarks')),
            if (!_isOpname)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _submitForApproval,
                onChanged: (v) => setState(() => _submitForApproval = v),
                title: const Text('Submit for approval after saving'),
              ),
            Text('System quantities as downloaded ${ago(stockPulled)}. '
                '${_isOpname ? 'Saved as a draft for a supervisor to post in ZARI.' : ''}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(children: [
              Text('${_lines.length} item(s) · $variances variance(s)', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              FilledButton(
                onPressed: _saving || _lines.isEmpty || _warehouseId == null ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ]),
            const SizedBox(height: 8),
            for (final l in _lines)
              Card(
                child: ListTile(
                  title: Text(l.item.name),
                  subtitle: Text([
                    l.item.code,
                    'System ${qty(l.systemQty)}',
                    if (l.batchNo?.isNotEmpty == true) 'Batch ${l.batchNo}',
                    if (l.serialNo?.isNotEmpty == true) 'S/N ${l.serialNo}',
                  ].join(' · ')),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(qty(l.countedQty), style: Theme.of(context).textTheme.titleMedium),
                      if (l.variance != 0)
                        Text('${l.variance > 0 ? '+' : ''}${qty(l.variance)}',
                            style: TextStyle(color: l.variance < 0 ? Theme.of(context).colorScheme.error : Colors.green.shade700)),
                    ],
                  ),
                  onTap: () => _editLine(l),
                  onLongPress: () => setState(() => _lines.remove(l)),
                ),
              ),
            if (_lines.isNotEmpty)
              Text('Tap a line to edit, long-press to remove.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
