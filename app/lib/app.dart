import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'shared/theme/app_theme.dart';

class NikonZControlApp extends ConsumerWidget {
  const NikonZControlApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Nikon Z Control',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      routerConfig: router,
    );
  }
}
