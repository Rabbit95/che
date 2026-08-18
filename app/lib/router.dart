import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import 'features/connection/connecting_screen.dart';
import 'features/control/live_view_screen.dart';
import 'features/control/parameter_sheet_screen.dart';
import 'features/discovery/discovery_screen.dart';
import 'features/discovery/onboarding_screen.dart';
import 'features/gallery/gallery_screen.dart';
import 'features/gallery/transfer_queue_screen.dart';

/// Named routes for programmatic navigation. Kept as constants so we don't
/// stringly-type paths across the codebase.
abstract final class AppRoute {
  AppRoute._();

  static const String discovery = '/';
  static const String onboarding = '/onboarding';
  static const String connecting = '/connecting';
  static const String liveView = '/live-view';
  static const String parameters = '/live-view/parameters';
  static const String gallery = '/gallery';
  static const String transfers = '/gallery/transfers';
}

final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: AppRoute.discovery,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoute.discovery,
        name: 'discovery',
        builder: (_, __) => const DiscoveryScreen(),
      ),
      GoRoute(
        path: AppRoute.onboarding,
        name: 'onboarding',
        builder: (_, __) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoute.connecting,
        name: 'connecting',
        builder: (_, state) {
          final q = state.uri.queryParameters;
          final channel = switch (q['channel']) {
            'usb' => TransportChannel.usb,
            'icc' => TransportChannel.icc,
            _ => TransportChannel.wifi,
          };
          return ConnectingScreen(
            host: q['host'] ?? '192.168.1.1',
            cameraName: q['name'] ?? 'Nikon Z',
            ssid: q['ssid'] ?? '',
            channel: channel,
            usbSerial: q['usbSerial'],
          );
        },
      ),
      GoRoute(
        path: AppRoute.liveView,
        name: 'liveView',
        builder: (_, __) => const LiveViewScreen(),
        routes: [
          GoRoute(
            path: 'parameters',
            name: 'parameters',
            builder: (_, __) => const ParameterSheetScreen(),
          ),
        ],
      ),
      GoRoute(
        path: AppRoute.gallery,
        name: 'gallery',
        builder: (_, __) => const GalleryScreen(),
        routes: [
          GoRoute(
            path: 'transfers',
            name: 'transfers',
            builder: (_, __) => const TransferQueueScreen(),
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
