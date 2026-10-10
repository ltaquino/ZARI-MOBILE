import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/auth/auth_controller.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
import 'features/sync/sync_controller.dart';

/// ZARI-FE's brand-600.
const _brand = Color(0xFF2563EB);

class ZariApp extends StatelessWidget {
  const ZariApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: _brand, brightness: b),
          inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
        );
    return MaterialApp(
      title: 'ZARI',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends ConsumerStatefulWidget {
  const _AuthGate();

  @override
  ConsumerState<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<_AuthGate> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(authControllerProvider.notifier).restore());
  }

  @override
  Widget build(BuildContext context) {
    // Start background sync whenever someone is signed in.
    ref.listen(authControllerProvider.select((a) => a.session?.userId), (prev, next) {
      if (next != null && prev != next) {
        ref.read(syncControllerProvider.notifier)
          ..stop()
          ..start();
      }
    });

    final auth = ref.watch(authControllerProvider);
    if (auth.restoring) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return auth.isSignedIn ? const HomeScreen() : const LoginScreen();
  }
}
