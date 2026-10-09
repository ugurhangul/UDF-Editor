import 'dart:io';

import 'package:go_router/go_router.dart';

import '../features/editor/editor_screen.dart';
import '../features/file_browser/file_browser_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/signing/signing_screen.dart';
import '../features/sync/sync_settings_screen.dart';

// ARCH-04/M-08: guard against navigating to reader/signing with a missing or
// nonexistent file path — bounce back to the file browser instead of crashing.
bool _hasValidPath(GoRouterState state) {
  final filePath = state.uri.queryParameters['path'];
  if (filePath == null || filePath.isEmpty) return false;
  return File(filePath).existsSync();
}

// Editor legitimately accepts no path (new document) — only reject a path
// that was explicitly provided but does not exist on disk.
bool _hasValidOptionalPath(GoRouterState state) {
  final filePath = state.uri.queryParameters['path'];
  if (filePath == null || filePath.isEmpty) return true;
  return File(filePath).existsSync();
}

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
      redirect: (context, state) => _hasValidPath(state) ? null : '/',
      builder: (context, state) {
        final filePath = state.uri.queryParameters['path'] ?? '';
        return ReaderScreen(filePath: filePath);
      },
    ),
    GoRoute(
      path: '/editor',
      name: 'editor',
      redirect: (context, state) => _hasValidOptionalPath(state) ? null : '/',
      builder: (context, state) {
        final filePath = state.uri.queryParameters['path'];
        final isNew = state.uri.queryParameters['new'] == 'true';
        return EditorScreen(filePath: filePath, isNewDocument: isNew);
      },
    ),
    GoRoute(
      path: '/signing',
      name: 'signing',
      redirect: (context, state) => _hasValidPath(state) ? null : '/',
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
