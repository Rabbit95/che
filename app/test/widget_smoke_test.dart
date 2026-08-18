import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nikon_z_control/features/discovery/discovery_screen.dart';
import 'package:nikon_z_control/shared/theme/app_theme.dart';

void main() {
  testWidgets('DiscoveryScreen renders app bar and camera cards',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const DiscoveryScreen(),
        ),
      ),
    );
    // Let the placeholder StreamProvider yield once.
    await tester.pump();

    expect(find.text('相机'), findsOneWidget);
    expect(find.text('Nikon Z8'), findsOneWidget);
    expect(find.text('Nikon Z6III'), findsOneWidget);
  });
}
