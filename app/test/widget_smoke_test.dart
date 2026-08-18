import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import 'package:nikon_z_control/features/discovery/discovery_screen.dart';
import 'package:nikon_z_control/shared/providers/connection_providers.dart';
import 'package:nikon_z_control/shared/theme/app_theme.dart';

void main() {
  testWidgets('DiscoveryScreen renders app bar and merged discovery entries',
      (tester) async {
    // Fake discovery output — one of every channel so we exercise the
    // section list + ChannelBadge branches. Real production data comes
    // from mDNS (bonsoir) + USB (quick_usb) + ICC (ImageCaptureCore); the
    // discovery screen doesn't care which source produced an entry.
    const fakeCameras = <DiscoveredCamera>[
      DiscoveredCamera(
        id: 'wifi-NIKON Z6III',
        name: 'NIKON Z6III',
        channel: TransportChannel.wifi,
        host: '192.168.1.42',
      ),
      DiscoveredCamera(
        id: 'usb-Z8-abc',
        name: 'Nikon Z8',
        channel: TransportChannel.usb,
      ),
    ];

    // GoRouter is required because the discovery card taps use
    // context.pushNamed — no navigation happens in this test but the
    // router has to be findable.
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const DiscoveryScreen(),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        GoRoute(
          name: 'connecting',
          path: '/connecting',
          builder: (_, __) => const SizedBox.shrink(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          discoveryProvider
              .overrideWith((ref) => Stream.value(fakeCameras)),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(),
          routerConfig: router,
        ),
      ),
    );
    // Let the StreamProvider yield its first snapshot.
    await tester.pump();

    expect(find.text('相机'), findsOneWidget);
    expect(find.text('NIKON Z6III'), findsOneWidget);
    expect(find.text('Nikon Z8'), findsOneWidget);
    expect(find.text('192.168.1.42'), findsOneWidget);
  });
}
