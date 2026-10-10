import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/format.dart';
import '../../shared/scanner_screen.dart';
import '../auth/auth_controller.dart';
import '../masterdata/master_data_repository.dart';
import '../sync/sync_controller.dart';
import 'item_detail_screen.dart';

class ItemListScreen extends ConsumerStatefulWidget {
  const ItemListScreen({super.key});

  @override
  ConsumerState<ItemListScreen> createState() => _ItemListScreenState();
}

class _ItemListScreenState extends ConsumerState<ItemListScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<ItemEntry> _items = [];
  int _total = 0;
  bool _loading = true;

  String get _branchId => ref.read(authControllerProvider).branchId!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(masterDataRepositoryProvider);
    final items = await repo.searchItems(_search.text, branchId: _branchId, limit: 100);
    final total = await repo.itemCount();
    if (!mounted) return;
    setState(() {
      _items = items;
      _total = total;
      _loading = false;
    });
  }

  Future<void> _open(ItemEntry e) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ItemDetailScreen(itemId: e.item.id)));

  Future<void> _scan() async {
    final code = await ScannerScreen.scan(context);
    if (code == null || !mounted) return;
    final match = await ref.read(masterDataRepositoryProvider).findByCode(code, branchId: _branchId);
    if (!mounted) return;
    if (match != null) {
      await _open(match);
    } else {
      _search.text = code;
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Reload after a background download lands.
    ref.listen(syncControllerProvider.select((s) => s.lastStockPull), (_, __) => _load());
    ref.listen(authControllerProvider.select((s) => s.branchId), (_, __) => _load());

    return Scaffold(
      appBar: AppBar(title: const Text('Items & Stock')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search $_total items by code or name',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: _scan),
              ),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 250), _load);
              },
              onSubmitted: (v) async {
                final match = await ref.read(masterDataRepositoryProvider).findByCode(v, branchId: _branchId);
                if (match != null && mounted) await _open(match);
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(
                        child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_total == 0
                            ? 'No items downloaded yet. Connect and pull down on the home screen to download.'
                            : 'No matching items.'),
                      ))
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final e = _items[i];
                          return ListTile(
                            title: Text(e.item.name),
                            subtitle: Text('${e.item.code}${e.item.isActive ? '' : ' · inactive'}'),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(money(e.price), style: Theme.of(context).textTheme.titleSmall),
                                Text(e.item.isStocked ? 'On hand ${qty(e.onHand)}' : 'Not stocked',
                                    style: TextStyle(
                                        color: e.item.isStocked && e.onHand <= 0
                                            ? Theme.of(context).colorScheme.error
                                            : null)),
                              ],
                            ),
                            onTap: () => _open(e),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
