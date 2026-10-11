import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/format.dart';
import '../../shared/item_picker.dart';
import '../auth/auth_controller.dart';
import '../masterdata/master_data_repository.dart';
import '../masterdata/models.dart';
import '../sync/sync_controller.dart';
import 'customer_picker.dart';
import 'line_editor.dart';
import 'pos_checkout_sheet.dart';
import 'pos_service.dart';
import 'receipt_screen.dart';
import 'sales_calculator.dart';

class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  RefRecord? _terminal;
  List<RefRecord> _terminals = [];
  List<RefRecord> _statutoryTypes = [];
  double? _maxDiscountPct;

  /// False when this user can't read Company settings (COMPANY:View), so the
  /// approval threshold is unknown offline and ZARI decides on sync.
  bool _capKnown = false;
  bool _loading = true;

  final List<CartLine> _lines = [];
  RefRecord? _customer;
  double _headerDiscountPct = 0;
  int _lineSeq = 0;

  String get _branchId => ref.read(authControllerProvider).branchId!;
  String get _terminalKey => 'zari.pos.terminal.${ref.read(authControllerProvider).session!.userId}.$_branchId';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final repo = ref.read(masterDataRepositoryProvider);
    final terminals = await repo.refList(RefEntity.posTerminal, branchId: _branchId);
    final statutory = await repo.refList(RefEntity.statutoryDiscountType);
    final company = await repo.company();
    final savedId = await ref.read(keyValueStoreProvider).read(_terminalKey);
    if (!mounted) return;
    setState(() {
      _terminals = terminals;
      _statutoryTypes = statutory;
      _capKnown = company != null;
      _maxDiscountPct = company?.json['maxUnapprovedDiscountPct'] == null ? null : company!.numField('maxUnapprovedDiscountPct');
      _terminal = terminals.where((t) => t.id == savedId).firstOrNull ?? (terminals.length == 1 ? terminals.first : null);
      _loading = false;
    });
    if (_terminal == null && terminals.length > 1) await _pickTerminal();
  }

  Future<void> _pickTerminal() async {
    final picked = await showModalBottomSheet<RefRecord>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Choose POS terminal')),
          for (final t in _terminals)
            ListTile(
              leading: const Icon(Icons.point_of_sale),
              title: Text('${t.code} — ${t.name}'),
              selected: t.id == _terminal?.id,
              onTap: () => Navigator.pop(ctx, t),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    await ref.read(keyValueStoreProvider).write(_terminalKey, picked.id);
    setState(() => _terminal = picked);
  }

  Future<void> _addItem() async {
    final entry = await ItemPickerScreen.pick(context, branchId: _branchId, sellableOnly: true, title: 'Add to sale');
    if (entry == null || !mounted) return;
    _addEntry(entry);
  }

  void _addEntry(ItemEntry entry) {
    final blocked = entry.posBlockReason;
    if (blocked != null) {
      _snack('${entry.item.code}: $blocked');
      return;
    }
    setState(() {
      // Same merge rule as ZARI-FE's PosPage: serialized items always get a
      // fresh qty-1 line (each unit needs its own serial no.).
      if (!entry.item.isSerialized) {
        final existing = _lines.where((l) => l.item.id == entry.item.id && l.statutoryDiscountTypeId == null).firstOrNull;
        if (existing != null) {
          existing.qty += entry.packQty; // a box barcode adds the whole box
          return;
        }
      }
      _lines.add(CartLine(
        key: 'l${_lineSeq++}',
        item: entry.item,
        qty: entry.item.isSerialized ? 1 : entry.packQty,
        unitPrice: entry.price ?? 0,
        defaultWarehouseId: entry.setting?.defaultWarehouseId,
      ));
    });
    if (entry.item.isSerialized) _editLine(_lines.last);
  }

  Future<void> _editLine(CartLine line) async {
    final result = await editSalesLine(context, line, statutoryTypes: _statutoryTypes, allowStatutory: true, allowSerial: true);
    if (result == false) setState(() => _lines.remove(line));
    if (result == true) setState(() {});
  }

  Future<Map<String, double>> _availability() async {
    final repo = ref.read(masterDataRepositoryProvider);
    final out = <String, double>{};
    for (final l in _lines) {
      if (!l.item.isStocked || l.defaultWarehouseId == null || out.containsKey(l.item.id)) continue;
      final bal = await repo.balanceAt(l.item.id, l.defaultWarehouseId!);
      out[l.item.id] = bal.qty - await repo.pendingPosQty(l.item.id, _branchId);
    }
    return out;
  }

  Future<void> _checkout() async {
    final problems = validatePosCart(
      lines: _lines,
      headerDiscountPct: _headerDiscountPct,
      maxUnapprovedDiscountPct: _maxDiscountPct,
      availableQty: await _availability(),
    );
    if (problems.isNotEmpty) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Can't check out yet"),
          content: Text(problems.map((p) => '• $p').join('\n')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      return;
    }
    final totals = CartTotals.of(_lines, headerDiscountPct: _headerDiscountPct);
    final methods = await ref.read(masterDataRepositoryProvider).refList(RefEntity.paymentMethod);
    methods.sort((a, b) => a.numField('displayOrder').compareTo(b.numField('displayOrder')));
    if (!mounted) return;
    final tenders = await PosCheckoutSheet.show(context, total: totals.total, methods: methods);
    if (tenders == null || !mounted) return;

    final auth = ref.read(authControllerProvider);
    final entry = await queuePosSale(
      outbox: ref.read(outboxRepositoryProvider),
      userId: auth.session!.userId,
      branchId: _branchId,
      terminal: _terminal!,
      customer: (_customer?.id.isEmpty ?? true) ? null : _customer,
      headerDiscountPct: _headerDiscountPct,
      lines: List.of(_lines),
      tenders: tenders,
    );
    setState(() {
      _lines.clear();
      _customer = null;
      _headerDiscountPct = 0;
    });
    await ref.read(syncControllerProvider.notifier).kick();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(entryId: entry.id)));
  }

  Future<void> _editHeaderDiscount() async {
    final ctl = TextEditingController(text: _headerDiscountPct == 0 ? '' : qty(_headerDiscountPct));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discount on whole sale'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            suffixText: '%',
            helperMaxLines: 3,
            helperText: !_capKnown
                ? "Your account can't read the company discount limit. A discount above it is rejected when the sale syncs."
                : _maxDiscountPct == null
                    ? null
                    : 'Up to ${qty(_maxDiscountPct!)}% at POS',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, parseNum(ctl.text) ?? 0), child: const Text('Apply')),
        ],
      ),
    );
    if (v != null && v >= 0 && v <= 100) setState(() => _headerDiscountPct = v);
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_terminals.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('POS Sale')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('No active POS terminal is set up for this branch (or none downloaded yet). '
                'Set one up in ZARI web under Sales › POS Terminals.'),
          ),
        ),
      );
    }
    final totals = CartTotals.of(_lines, headerDiscountPct: _headerDiscountPct);
    final theme = Theme.of(context);
    return PopScope(
      canPop: _lines.isEmpty,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Abandon this sale?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Abandon')),
            ],
          ),
        );
        if (ok == true && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('POS Sale'),
          actions: [
            TextButton.icon(
              onPressed: _terminals.length > 1 ? _pickTerminal : null,
              icon: const Icon(Icons.point_of_sale, size: 18),
              label: Text(_terminal?.code ?? 'Terminal'),
            ),
          ],
        ),
        body: Column(children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(_customer?.name ?? 'Walk-in Customer'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final c = await CustomerPickerScreen.pick(context, allowWalkIn: true);
              if (c != null) setState(() => _customer = c.id.isEmpty ? null : c);
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.shopping_cart_outlined, size: 48, color: theme.colorScheme.outline),
                      const SizedBox(height: 8),
                      const Text('Scan or search to add items'),
                    ]),
                  )
                : ListView.separated(
                    itemCount: _lines.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final l = _lines[i];
                      final c = l.calc;
                      return ListTile(
                        title: Text(l.item.name),
                        subtitle: Text([
                          '${qty(l.qty)} × ${money(l.unitPrice)}',
                          if (l.statutoryDiscountTypeId != null) 'Statutory disc.',
                          if (l.discountPct > 0) '${qty(l.discountPct)}% off',
                          if (l.serialNo != null) 'S/N ${l.serialNo}',
                          if (l.item.isSerialized && l.serialNo == null) 'Serial no. needed',
                        ].join(' · ')),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (!l.item.isSerialized)
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () => setState(() => l.qty > 1 ? l.qty -= 1 : _lines.remove(l)),
                            ),
                          Text(money(c.net), style: theme.textTheme.titleSmall),
                        ]),
                        onTap: () => _editLine(l),
                      );
                    },
                  ),
          ),
          Material(
            elevation: 8,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    TextButton.icon(
                      onPressed: _lines.isEmpty ? null : _editHeaderDiscount,
                      icon: const Icon(Icons.percent, size: 18),
                      label: Text(_headerDiscountPct == 0 ? 'Discount' : '${qty(_headerDiscountPct)}% off'),
                    ),
                    const Spacer(),
                    Text('VAT ${money(totals.vat)}', style: theme.textTheme.bodySmall),
                  ]),
                  Row(children: [
                    OutlinedButton.icon(
                      onPressed: _addItem,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Add item'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _lines.isEmpty || _terminal == null ? null : _checkout,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        child: Text('Charge ${money(totals.total)}', style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
