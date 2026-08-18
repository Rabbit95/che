import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'shared/providers/connection_providers.dart';
import 'shared/theme/app_theme.dart';

class NikonZControlApp extends ConsumerWidget {
  const NikonZControlApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the transport-disconnect watcher alive for the process
    // lifetime — it wipes activeConnectionProvider when a session dies
    // (unplug, cable pull, etc), which triggers UI unwind.
    ref.watch(transportDisconnectWatcherProvider);
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Nikon Z Control',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      routerConfig: router,
    );
  }
}
