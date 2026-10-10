import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../masterdata/models.dart';

/// Search cached customers by name, member no. or phone. Pops with the
/// chosen record, or with [walkIn] when the walk-in option is offered.
class CustomerPickerScreen extends ConsumerStatefulWidget {
  const CustomerPickerScreen({super.key, this.allowWalkIn = false});

  final bool allowWalkIn;

  static const walkIn = RefRecord(RefEntity.customer, {'id': '', 'name': 'Walk-in Customer'});

  static Future<RefRecord?> pick(BuildContext context, {bool allowWalkIn = false}) => Navigator.of(context)
      .push<RefRecord>(MaterialPageRoute(builder: (_) => CustomerPickerScreen(allowWalkIn: allowWalkIn)));

  @override
  ConsumerState<CustomerPickerScreen> createState() => _CustomerPickerScreenState();
}

class _CustomerPickerScreenState extends ConsumerState<CustomerPickerScreen> {
  Timer? _debounce;
  List<RefRecord> _results = [];

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load(String q) async {
    final r = await ref.read(masterDataRepositoryProvider).searchCustomers(q);
    if (mounted) setState(() => _results = r);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customer')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Name, member no. or phone', prefixIcon: Icon(Icons.search)),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), () => _load(v));
            },
          ),
        ),
        if (widget.allowWalkIn)
          ListTile(
            leading: const Icon(Icons.directions_walk),
            title: const Text('Walk-in Customer'),
            onTap: () => Navigator.pop(context, CustomerPickerScreen.walkIn),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: _results.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final c = _results[i];
              final sub = [c.strField('memberNo'), c.strField('phone'), c.strField('type')]
                  .whereType<String>()
                  .where((s) => s.isNotEmpty)
                  .join(' · ');
              return ListTile(
                title: Text(c.name),
                subtitle: sub.isEmpty ? null : Text(sub),
                trailing: c.numField('standingDiscountPct') > 0 ? Text('${c.numField('standingDiscountPct')}% disc.') : null,
                onTap: () => Navigator.pop(context, c),
              );
            },
          ),
        ),
      ]),
    );
  }
}
