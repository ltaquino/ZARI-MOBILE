import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth_controller.dart';
import '../features/auth/auth_repository.dart';
import '../features/sync/sync_controller.dart';
import '../features/sync/sync_screen.dart';

/// App-bar chip: online/offline + how much is still waiting to sync.
class SyncChip extends ConsumerWidget {
  const SyncChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, label) = s.busy
        ? (Icons.sync, scheme.primary, 'Syncing')
        : s.attentionCount > 0
            ? (Icons.error_outline, scheme.error, '${s.attentionCount} need attention')
            : !s.online
                ? (Icons.cloud_off, scheme.outline, s.pendingCount > 0 ? '${s.pendingCount} offline' : 'Offline')
                : s.pendingCount > 0
                    ? (Icons.cloud_upload_outlined, scheme.primary, '${s.pendingCount} to send')
                    : (Icons.cloud_done_outlined, Colors.green.shade700, 'Synced');
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: s.busy
            ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color))
            : Icon(icon, size: 18, color: color),
        label: Text(label),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncScreen())),
      ),
    );
  }
}

/// Shown under the app bar when the user has to act: session expired, or
/// signed in offline.
class SessionBanner extends ConsumerWidget {
  const SessionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final sync = ref.watch(syncControllerProvider);
    if (auth.needsReauth) {
      return MaterialBanner(
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
        content: const Text('Session expired. Sign in again to send your saved work to ZARI.'),
        actions: [TextButton(onPressed: () => showReauthDialog(context, ref), child: const Text('SIGN IN'))],
      );
    }
    if (!sync.online) {
      return MaterialBanner(
        content: Text(auth.offlineSession
            ? 'Working offline (signed in on this device). Everything you save will sync automatically.'
            : 'Working offline. Everything you save will sync automatically.'),
        leading: const Icon(Icons.cloud_off),
        actions: [
          TextButton(
              onPressed: () => ref.read(syncControllerProvider.notifier).syncNow(), child: const Text('RETRY')),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}

Future<void> showReauthDialog(BuildContext context, WidgetRef ref) async {
  final pw = TextEditingController();
  String? error;
  var busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Sign in again'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ref.read(authControllerProvider).session?.email ?? ''),
            const SizedBox(height: 12),
            TextField(
              controller: pw,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Password', errorText: error),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await ref.read(authControllerProvider.notifier).reauthenticate(pw.text);
                      if (ctx.mounted) Navigator.pop(ctx);
                      await ref.read(syncControllerProvider.notifier).syncNow();
                    } on AuthFailure catch (e) {
                      setState(() {
                        error = e.message;
                        busy = false;
                      });
                    }
                  },
            child: const Text('Sign in'),
          ),
        ],
      ),
    ),
  );
}
