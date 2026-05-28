import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:aqualerta/features/alerts/presentation/bloc/alerts_bloc.dart';
import 'package:aqualerta/features/alerts/domain/entities/alert.dart';
import 'package:aqualerta/core/constants/app_colors.dart';
import 'package:aqualerta/core/constants/app_typography.dart';
import 'package:aqualerta/core/constants/app_spacing.dart';
import 'package:aqualerta/shared/widgets/shared_widgets.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  String? _severityFilter;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    context.read<AlertsBloc>().add(AlertsLoad());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          // ── Header ──────────────────────────────────────────
          Container(
            color: AppColors.bg1,
            padding: EdgeInsets.fromLTRB(
                AppSpacing.lg, topPad + AppSpacing.md, AppSpacing.lg, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.sevHighBg,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.notifications_rounded,
                          size: 18, color: AppColors.sevHigh),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Alertas', style: AppTypography.h2),
                        BlocBuilder<AlertsBloc, AlertsState>(
                          builder: (_, state) {
                            final count = state is AlertsLoaded
                                ? state.activeCount
                                : 0;
                            return Text(
                              count > 0
                                  ? '$count ativo${count > 1 ? 's' : ''}'
                                  : 'Sem alertas ativos',
                              style: AppTypography.caption.copyWith(
                                color: count > 0
                                    ? AppColors.sevHigh
                                    : AppColors.textSecondary,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () =>
                          context.read<AlertsBloc>().add(AlertsRefresh()),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppColors.bg2,
                          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
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
                    Tab(text: 'Ativos'),
                    Tab(text: 'Histórico'),
                  ],
                ),
              ],
            ),
          ),

          // ── Severity filter ──────────────────────────────────
          _buildSeverityFilter(),
          const Divider(height: 1),

          // ── Body ─────────────────────────────────────────────
          Expanded(
            child: BlocBuilder<AlertsBloc, AlertsState>(
              builder: (context, state) {
                if (state is AlertsLoading || state is AlertsInitial) {
                  return _buildSkeleton();
                }
                if (state is AlertsError) {
                  return EmptyState(
                    icon: Icons.error_outline_rounded,
                    title: 'Erro ao carregar',
                    subtitle: state.message,
                    action: ElevatedButton(
                      onPressed: () =>
                          context.read<AlertsBloc>().add(AlertsLoad()),
                      child: const Text('Tentar novamente'),
                    ),
                  );
                }
                if (state is AlertsLoaded) {
                  final ativos = state.filteredAlerts
                      .where((a) => a.isActive)
                      .toList();
                  final historico = state.filteredAlerts
                      .where((a) => !a.isActive)
                      .toList();
                  return TabBarView(
                    controller: _tabs,
                    children: [
                      _buildAlertsList(ativos,
                          emptyMessage: 'Nenhum alerta ativo'),
                      _buildAlertsList(historico,
                          emptyMessage: 'Nenhum alerta anterior'),
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

  Widget _buildSeverityFilter() {
    final severities = [null, 'CRITICAL', 'HIGH', 'MEDIUM', 'LOW'];
    final labels = {
      null: 'Todos',
      'CRITICAL': 'Crítico',
      'HIGH': 'Alto',
      'MEDIUM': 'Médio',
      'LOW': 'Baixo',
    };

    return Container(
      color: AppColors.bg1,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: severities.map((sev) {
            final isActive = _severityFilter == sev;
            final color = sev != null
                ? AppColors.bySeverity(sev)
                : AppColors.brandPrimary;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () {
                  setState(() => _severityFilter = sev);
                  context
                      .read<AlertsBloc>()
                      .add(AlertsFilterChanged(severity: sev));
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: isActive
                        ? color.withValues(alpha: 0.15)
                        : AppColors.bg2,
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusFull),
                    border: Border.all(
                      color: isActive ? color : AppColors.border,
                      width: isActive ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    labels[sev]!,
                    style: AppTypography.caption.copyWith(
                      color: isActive ? color : AppColors.textSecondary,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildAlertsList(List<Alert> alerts,
      {required String emptyMessage}) {
    if (alerts.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: emptyMessage,
        subtitle: 'As regiões monitoradas estão dentro da normalidade.',
      );
    }
    return RefreshIndicator(
      color: AppColors.brandPrimary,
      backgroundColor: AppColors.bg2,
      onRefresh: () async =>
          context.read<AlertsBloc>().add(AlertsRefresh()),
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: alerts.length,
        separatorBuilder: (_, __) =>
            const SizedBox(height: AppSpacing.sm),
        itemBuilder: (_, i) => _AlertCard(
          alert: alerts[i],
          onAcknowledge: () => context
              .read<AlertsBloc>()
              .add(AlertAcknowledge(alerts[i].id)),
        ),
      ),
    );
  }

  Widget _buildSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: 5,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Container(
          height: 110,
          decoration: BoxDecoration(
            color: AppColors.bg2,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
          ),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                ShimmerBox(width: 70, height: 22, borderRadius: 20),
                Spacer(),
                ShimmerBox(width: 60, height: 14),
              ]),
              SizedBox(height: 12),
              ShimmerBox(width: double.infinity, height: 16),
              SizedBox(height: 6),
              ShimmerBox(width: 200, height: 14),
            ],
          ),
        ),
      ),
    );
  }
}

// ── AlertCard ─────────────────────────────────────────────────
class _AlertCard extends StatelessWidget {
  final Alert alert;
  final VoidCallback onAcknowledge;

  const _AlertCard({required this.alert, required this.onAcknowledge});

  @override
  Widget build(BuildContext context) {
    final color = AppColors.bySeverity(alert.severity);
    final timeAgo = _timeAgo(alert.issuedAt);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border(
          left: BorderSide(color: color, width: 3),
          top: const BorderSide(color: AppColors.border),
          right: const BorderSide(color: AppColors.border),
          bottom: const BorderSide(color: AppColors.border),
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              SeverityBadge(severity: alert.severity),
              if (!alert.isActive)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.bg3,
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusFull),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text('RESOLVIDO',
                        style: AppTypography.label
                            .copyWith(color: AppColors.textDisabled)),
                  ),
                ),
              const Spacer(),
              Text(timeAgo,
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // Title
          Text(alert.title,
              style: AppTypography.title
                  .copyWith(color: AppColors.textPrimary)),
          const SizedBox(height: 4),

          // Body
          Text(
            alert.body,
            style: AppTypography.body
                .copyWith(color: AppColors.textSecondary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.md),

          // Footer
          Row(
            children: [
              const Icon(Icons.location_on_outlined,
                  size: 13, color: AppColors.textDisabled),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  alert.regionName,
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (alert.isActive && !alert.acknowledged)
                GestureDetector(
                  onTap: onAcknowledge,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.bg3,
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusFull),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      'Confirmar',
                      style: AppTypography.caption.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              if (alert.acknowledged)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        size: 13, color: AppColors.sevLow),
                    const SizedBox(width: 4),
                    Text('Visto',
                        style: AppTypography.caption
                            .copyWith(color: AppColors.sevLow)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}min atrás';
    if (diff.inHours < 24) return '${diff.inHours}h atrás';
    return DateFormat('dd/MM HH:mm').format(dt);
  }
}
