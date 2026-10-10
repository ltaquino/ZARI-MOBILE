import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../features/masterdata/master_data_repository.dart';
import 'format.dart';
import 'scanner_screen.dart';

/// Search-or-scan item lookup over the offline catalog. Submitting the
/// field (what a keyboard-wedge scanner does after a scan) tries an exact
/// item-code match first and returns it straight away.
class ItemPickerScreen extends ConsumerStatefulWidget {
  const ItemPickerScreen({super.key, required this.branchId, this.sellableOnly = false, this.title = 'Find item'});

  final String branchId;
  final bool sellableOnly;
  final String title;

  static Future<ItemEntry?> pick(BuildContext context, {required String branchId, bool sellableOnly = false, String? title}) =>
      Navigator.of(context).push<ItemEntry>(MaterialPageRoute(
          builder: (_) => ItemPickerScreen(branchId: branchId, sellableOnly: sellableOnly, title: title ?? 'Find item')));

  @override
  ConsumerState<ItemPickerScreen> createState() => _ItemPickerScreenState();
}

class _ItemPickerScreenState extends ConsumerState<ItemPickerScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<ItemEntry> _results = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(String q) async {
    final results = await ref
        .read(masterDataRepositoryProvider)
        .searchItems(q, branchId: widget.branchId, sellableOnly: widget.sellableOnly);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  Future<void> _submitCode(String code) async {
    if (code.trim().isEmpty) return;
    final match = await ref.read(masterDataRepositoryProvider).findByCode(code, branchId: widget.branchId);
    if (!mounted) return;
    if (match != null) {
      Navigator.of(context).pop(match);
    } else {
      _search.text = code;
      await _load(code);
      if (mounted && _results.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No item with code "$code" in the offline catalog.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Item code or name',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Scan with camera',
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: () async {
                    final code = await ScannerScreen.scan(context);
                    if (code != null) await _submitCode(code);
                  },
                ),
              ),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 250), () => _load(v));
              },
              onSubmitted: _submitCode,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? const Center(child: Text('No matching items. Download the latest data if this looks wrong.'))
                    : ListView.separated(
                        itemCount: _results.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final e = _results[i];
                          final blocked = widget.sellableOnly ? e.posBlockReason : null;
                          return ListTile(
                            enabled: blocked == null,
                            title: Text(e.item.name),
                            subtitle: Text(blocked ?? '${e.item.code} · On hand ${qty(e.onHand)}'),
                            trailing: Text(money(e.price), style: Theme.of(context).textTheme.titleSmall),
                            onTap: () => Navigator.of(context).pop(e),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
