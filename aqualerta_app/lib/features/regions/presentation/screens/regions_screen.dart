import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:aqualerta/features/regions/presentation/bloc/regions_bloc.dart';
import 'package:aqualerta/features/regions/domain/entities/monitored_region.dart';
import 'package:aqualerta/core/constants/app_colors.dart';
import 'package:aqualerta/core/constants/app_typography.dart';
import 'package:aqualerta/core/constants/app_spacing.dart';
import 'package:aqualerta/shared/widgets/shared_widgets.dart';

class RegionsScreen extends StatefulWidget {
  const RegionsScreen({super.key});

  @override
  State<RegionsScreen> createState() => _RegionsScreenState();
}

class _RegionsScreenState extends State<RegionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    context.read<RegionsBloc>().add(RegionsLoad());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: BlocConsumer<RegionsBloc, RegionsState>(
              listener: (context, state) {
                if (state is RegionsError) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(state.message),
                      backgroundColor: AppColors.error,
                    ),
                  );
                }
              },
              builder: (context, state) {
                if (state is RegionsLoading) {
                  return const Center(
                    child: CircularProgressIndicator(
                        color: AppColors.brandPrimary),
                  );
                }
                if (state is RegionsLoaded) {
                  return TabBarView(
                    controller: _tabs,
                    children: [
                      _buildSubscribedList(state),
                      _buildDiscoverList(state),
                    ],
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: AppColors.bg1,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + AppSpacing.md,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        bottom: 0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.brandGlow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.map_outlined,
                    size: 18, color: AppColors.brandPrimary),
              ),
              const SizedBox(width: 10),
              const Text('Regiões', style: AppTypography.h2),
              const Spacer(),
              GestureDetector(
                onTap: () =>
                    context.read<RegionsBloc>().add(RegionsLoad()),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.bg2,
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusSm),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: const Icon(Icons.refresh_rounded,
                      size: 18, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          TabBar(
            controller: _tabs,
            labelStyle: AppTypography.bodyStrong,
            unselectedLabelStyle: AppTypography.body,
            labelColor: AppColors.brandPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.brandPrimary,
            indicatorWeight: 2,
            dividerColor: Colors.transparent,
            tabs: const [
              Tab(text: 'Monitorando'),
              Tab(text: 'Descobrir'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSubscribedList(RegionsLoaded state) {
    if (state.subscribedRegions.isEmpty) {
      return EmptyState(
        icon: Icons.add_location_alt_outlined,
        title: 'Nenhuma região',
        subtitle:
            'Adicione regiões para monitorar enchentes e receber alertas.',
        action: ElevatedButton.icon(
          onPressed: () => _tabs.animateTo(1),
          icon: const Icon(Icons.explore_rounded, size: 18),
          label: const Text('Descobrir regiões'),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.brandPrimary,
      backgroundColor: AppColors.bg2,
      onRefresh: () async =>
          context.read<RegionsBloc>().add(RegionsLoad()),
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: state.subscribedRegions.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (_, i) => _RegionCard(
          region: state.subscribedRegions[i],
          isSubscribed: true,
          onToggle: () => context
              .read<RegionsBloc>()
              .add(RegionsUnsubscribe(state.subscribedRegions[i].id)),
          onToggleNotification: (notify) => context
              .read<RegionsBloc>()
              .add(RegionsUpdateNotification(
                state.subscribedRegions[i].id,
                notify,
                state.subscribedRegions[i].minSeverity,
              )),
        ),
      ),
    );
  }

  Widget _buildDiscoverList(RegionsLoaded state) {
    final available = state.availableToSubscribe;

    if (available.isEmpty) {
      return const EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'Todas as regiões adicionadas',
        subtitle: 'Você já monitora todas as regiões disponíveis.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: available.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (_, i) => _RegionCard(
        region: available[i],
        isSubscribed: false,
        onToggle: () => context
            .read<RegionsBloc>()
            .add(RegionsSubscribe(available[i].id)),
        onToggleNotification: (_) {},
      ),
    );
  }
}

// ── RegionCard ────────────────────────────────────────────────
class _RegionCard extends StatefulWidget {
  final MonitoredRegion region;
  final bool isSubscribed;
  final VoidCallback onToggle;
  final ValueChanged<bool> onToggleNotification;

  const _RegionCard({
    required this.region,
    required this.isSubscribed,
    required this.onToggle,
    required this.onToggleNotification,
  });

  @override
  State<_RegionCard> createState() => _RegionCardState();
}

class _RegionCardState extends State<_RegionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.region;
    final hasAlert = r.lastSeverity != null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: hasAlert
              ? AppColors.bySeverity(r.lastSeverity!).withValues(alpha: 0.3)
              : AppColors.border,
        ),
      ),
      child: Column(
        children: [
          // Main row
          GestureDetector(
            onTap: () =>
                setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  // State badge
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.bg3,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Center(
                      child: Text(
                        r.stateCode,
                        style: AppTypography.label.copyWith(
                            color: AppColors.textPrimary, fontSize: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),

                  // Name & info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name, style: AppTypography.title),
                        const SizedBox(height: 2),
                        Text(
                          '${r.areaKm2.toStringAsFixed(0)} km²'
                          '${r.municipality != null ? ' · ${r.municipality}' : ''}',
                          style: AppTypography.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: AppSpacing.sm),

                  // Subscribe toggle
                  GestureDetector(
                    onTap: widget.onToggle,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: widget.isSubscribed
                            ? AppColors.brandGlow
                            : AppColors.bg3,
                        borderRadius:
                            BorderRadius.circular(AppSpacing.radiusFull),
                        border: Border.all(
                          color: widget.isSubscribed
                              ? AppColors.brandPrimary
                              : AppColors.border,
                        ),
                      ),
                      child: Text(
                        widget.isSubscribed ? 'Monitorando' : '+ Adicionar',
                        style: AppTypography.caption.copyWith(
                          color: widget.isSubscribed
                              ? AppColors.brandPrimary
                              : AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Expanded: notification settings
          if (_expanded && widget.isSubscribed)
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  const Icon(Icons.notifications_outlined,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  const Text('Notificações',
                      style: AppTypography.body),
                  const Spacer(),
                  Switch(
                    value: r.notificationsEnabled,
                    onChanged: widget.onToggleNotification,
                    activeThumbColor: AppColors.brandPrimary,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
