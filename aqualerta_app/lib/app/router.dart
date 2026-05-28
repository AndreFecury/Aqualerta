import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:aqualerta/core/constants/app_colors.dart';
import 'package:aqualerta/core/constants/app_typography.dart';
import 'package:aqualerta/features/map/presentation/bloc/map_bloc.dart';
import 'package:aqualerta/features/map/presentation/screens/map_screen.dart';
import 'package:aqualerta/features/alerts/presentation/bloc/alerts_bloc.dart';
import 'package:aqualerta/features/alerts/presentation/screens/alerts_screen.dart';
import 'package:aqualerta/features/regions/presentation/bloc/regions_bloc.dart';
import 'package:aqualerta/features/regions/presentation/screens/regions_screen.dart';
import 'package:aqualerta/features/settings/presentation/screens/settings_screen.dart';
import 'package:aqualerta/features/map/data/datasources/map_remote_datasource.dart';
import 'package:aqualerta/features/alerts/data/datasources/alerts_remote_datasource.dart';
import 'package:aqualerta/features/regions/data/datasources/regions_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/login_screen.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

final router = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/map',
  redirect: (context, state) {
    final isLoggedIn = Supabase.instance.client.auth.currentUser != null;
    final isLoginRoute = state.matchedLocation == '/login';
    if (!isLoggedIn && !isLoginRoute) return '/login';
    if (isLoggedIn && isLoginRoute) return '/map';
    return null;
  },
  routes: [
    // Login
    GoRoute(
      path: '/login',
      builder: (_, __) => const LoginScreen(),
    ),

    // Main shell with bottom nav
    ShellRoute(
      navigatorKey: _shellNavigatorKey,
      builder: (context, state, child) => _AppShell(child: child),
      routes: [
        GoRoute(
          path: '/map',
          pageBuilder: (_, __) => const NoTransitionPage(child: MapScreen()),
        ),
        GoRoute(
          path: '/alerts',
          pageBuilder: (_, __) =>
              const NoTransitionPage(child: AlertsScreen()),
        ),
        GoRoute(
          path: '/regions',
          pageBuilder: (_, __) =>
              const NoTransitionPage(child: RegionsScreen()),
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (_, __) =>
              const NoTransitionPage(child: SettingsScreen()),
        ),
      ],
    ),
  ],
);

// ── AppShell ─────────────────────────────────────────────────
class _AppShell extends StatelessWidget {
  final Widget child;
  const _AppShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => MapBloc(MapRemoteDatasource())),
        BlocProvider(create: (_) => AlertsBloc(AlertsRemoteDatasource())),
        BlocProvider(create: (_) => RegionsBloc(RegionsRemoteDatasource())),
      ],
      child: Scaffold(
        body: child,
        bottomNavigationBar: _BottomNav(),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  final _routes = ['/map', '/alerts', '/regions', '/settings'];

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final idx = _routes.indexWhere((r) => location.startsWith(r));
    return idx >= 0 ? idx : 0;
  }

  @override
  Widget build(BuildContext context) {
    final idx = _currentIndex(context);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg1,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              _NavItem(
                icon: Icons.map_rounded,
                iconActive: Icons.map_rounded,
                label: 'Mapa',
                active: idx == 0,
                onTap: () => context.go('/map'),
                badge: 0,
              ),
              _NavItem(
                icon: Icons.notifications_outlined,
                iconActive: Icons.notifications_rounded,
                label: 'Alertas',
                active: idx == 1,
                onTap: () => context.go('/alerts'),
                badge: 0,
              ),
              _NavItem(
                icon: Icons.explore_outlined,
                iconActive: Icons.explore_rounded,
                label: 'Regiões',
                active: idx == 2,
                onTap: () => context.go('/regions'),
                badge: 0,
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                iconActive: Icons.settings_rounded,
                label: 'Config',
                active: idx == 3,
                onTap: () => context.go('/settings'),
                badge: 0,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData iconActive;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badge;

  const _NavItem({
    required this.icon,
    required this.iconActive,
    required this.label,
    required this.active,
    required this.onTap,
    required this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 40,
                  height: 32,
                  decoration: BoxDecoration(
                    color: active
                        ? AppColors.brandGlow
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    active ? iconActive : icon,
                    size: 22,
                    color: active
                        ? AppColors.brandPrimary
                        : AppColors.textSecondary,
                  ),
                ),
                if (badge > 0)
                  Positioned(
                    top: -3,
                    right: -3,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: AppColors.sevHigh,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '$badge',
                          style: AppTypography.label.copyWith(
                            fontSize: 9,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: AppTypography.label.copyWith(
                color: active
                    ? AppColors.brandPrimary
                    : AppColors.textDisabled,
                fontSize: 10,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
