import 'package:go_router/go_router.dart';

import '../features/editor/editor_screen.dart';
import '../features/file_browser/file_browser_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/signing/signing_screen.dart';
import '../features/sync/sync_settings_screen.dart';

/// Application route configuration using GoRouter.
final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => const FileBrowserScreen(),
    ),
    GoRoute(
      path: '/reader',
      name: 'reader',
      builder: (context, state) {
        final filePath = state.uri.queryParameters['path'] ?? '';
        return ReaderScreen(filePath: filePath);
      },
    ),
    GoRoute(
      path: '/editor',
      name: 'editor',
      builder: (context, state) {
        final filePath = state.uri.queryParameters['path'];
        final isNew = state.uri.queryParameters['new'] == 'true';
        return EditorScreen(filePath: filePath, isNewDocument: isNew);
      },
    ),
    GoRoute(
      path: '/signing',
      name: 'signing',
      builder: (context, state) {
        final filePath = state.uri.queryParameters['path'] ?? '';
        return SigningScreen(filePath: filePath);
      },
    ),
    GoRoute(
      path: '/sync-settings',
      name: 'syncSettings',
      builder: (context, state) => const SyncSettingsScreen(),
    ),
  ],
);
