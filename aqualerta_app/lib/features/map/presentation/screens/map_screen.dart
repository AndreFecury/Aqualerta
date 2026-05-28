import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:aqualerta/features/map/presentation/bloc/map_bloc.dart';
import 'package:aqualerta/features/map/domain/entities/flood_event.dart';
import 'package:aqualerta/core/constants/app_colors.dart';
import 'package:aqualerta/core/constants/app_typography.dart';
import 'package:aqualerta/core/constants/app_spacing.dart';
import 'package:aqualerta/shared/widgets/shared_widgets.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  FloodEvent? _selectedEvent;
  bool _showLegend = false;

  static const _amazonCenter = LatLng(-3.4653, -62.2159);

  @override
  void initState() {
    super.initState();
    context.read<MapBloc>().add(MapLoadEvents());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      body: BlocBuilder<MapBloc, MapState>(
        builder: (context, state) {
          return Stack(
            children: [
              // ── Mapa base ──────────────────────────────────
              _buildMap(state),

              // ── Top bar ────────────────────────────────────
              _buildTopBar(state),

              // ── Filtros de severidade ──────────────────────
              _buildSeverityFilters(state),

              // ── Legend toggle ──────────────────────────────
              Positioned(
                right: AppSpacing.lg,
                bottom: _selectedEvent != null ? 260 : 120,
                child: _buildMapControl(
                  icon: Icons.layers_rounded,
                  onTap: () => setState(() => _showLegend = !_showLegend),
                  active: _showLegend,
                ),
              ),

              // ── Recenter ───────────────────────────────────
              Positioned(
                right: AppSpacing.lg,
                bottom: _selectedEvent != null ? 200 : 60,
                child: _buildMapControl(
                  icon: Icons.my_location_rounded,
                  onTap: () => _mapController.move(_amazonCenter, 5),
                ),
              ),

              // ── Legenda ────────────────────────────────────
              if (_showLegend) _buildLegend(),

              // ── Bottom sheet do evento ─────────────────────
              if (_selectedEvent != null)
                _buildEventSheet(_selectedEvent!),

              // ── Loading overlay ────────────────────────────
              if (state is MapLoading) _buildLoadingOverlay(),

              // ── Error ──────────────────────────────────────
              if (state is MapError) _buildError(state.message),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMap(MapState state) {
    final events =
        state is MapLoaded ? state.filteredEvents : <FloodEvent>[];

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _amazonCenter,
        initialZoom: 5,
        backgroundColor: const Color(0xFF0A1628),
        onTap: (_, __) => setState(() => _selectedEvent = null),
      ),
      children: [
        // OSM tile layer
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'br.com.aqualerta',
          tileBuilder: _darkTileBuilder,
          maxZoom: 19,
        ),

        // Flood polygons overlay
        if (events.isNotEmpty)
          PolygonLayer(
            polygons: events.expand((event) {
              // Gerar polígono aproximado pelo centro se não houver coords reais
              return [_buildApproxPolygon(event)];
            }).whereType<Polygon>().toList(),
          ),

        // Markers dos eventos
        MarkerLayer(
          markers: events.map((event) => _buildMarker(event)).toList(),
        ),
      ],
    );
  }

  // Tile builder escurecido para estética dark
  Widget _darkTileBuilder(
      BuildContext context, Widget tileWidget, TileImage tile) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        0.3, 0, 0, 0, 0,
        0, 0.35, 0, 0, 0,
        0, 0, 0.5, 0, 0,
        0, 0, 0, 1, 0,
      ]),
      child: tileWidget,
    );
  }

  Polygon? _buildApproxPolygon(FloodEvent event) {
    if (event.centerLat == null || event.centerLng == null) return null;
    final lat = event.centerLat!;
    final lng = event.centerLng!;
    final delta = 0.15 + (event.floodedAreaKm2 / 1000);
    final color = AppColors.bySeverity(event.severity);

    return Polygon(
      points: [
        LatLng(lat + delta, lng - delta),
        LatLng(lat + delta, lng + delta),
        LatLng(lat - delta, lng + delta),
        LatLng(lat - delta, lng - delta),
      ],
      color: color.withValues(alpha: 0.25),
      borderColor: color.withValues(alpha: 0.7),
      borderStrokeWidth: 1.5,
    );
  }

  Marker _buildMarker(FloodEvent event) {
    final color = AppColors.bySeverity(event.severity);
    final isSel = _selectedEvent?.id == event.id;

    return Marker(
      point: LatLng(
        event.centerLat ?? -3.4,
        event.centerLng ?? -62.0,
      ),
      width: isSel ? 48 : 36,
      height: isSel ? 48 : 36,
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedEvent = event);
          _mapController.move(
            LatLng(event.centerLat ?? -3.4, event.centerLng ?? -62.0),
            8,
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.2),
            border: Border.all(
              color: color,
              width: isSel ? 2.5 : 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: isSel ? 0.5 : 0.3),
                blurRadius: isSel ? 16 : 8,
              ),
            ],
          ),
          child: Center(
            child: Icon(
              _severityIcon(event.severity),
              color: color,
              size: isSel ? 22 : 16,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(MapState state) {
    final count = state is MapLoaded ? state.filteredEvents.length : 0;
    final activeHigh = state is MapLoaded
        ? state.filteredEvents
            .where((e) => e.severity == 'HIGH' || e.severity == 'CRITICAL')
            .length
        : 0;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bg0, AppColors.bg0.withValues(alpha: 0)],
          ),
        ),
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + AppSpacing.sm,
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          bottom: AppSpacing.xl,
        ),
        child: Row(
          children: [
            // Logo + título
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.waterFlood, AppColors.brandPrimary],
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.water_drop_rounded,
                          color: Colors.white, size: 16),
                    ),
                    const SizedBox(width: 8),
                    Text('AQUALERTA',
                        style: AppTypography.bodyStrong.copyWith(
                          color: AppColors.textPrimary,
                          letterSpacing: 2,
                        )),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$count eventos · ${DateFormat('HH:mm').format(DateTime.now())}',
                  style: AppTypography.caption,
                ),
              ],
            ),
            const Spacer(),
            // Alert indicator
            if (activeHigh > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.sevHighBg,
                  borderRadius:
                      BorderRadius.circular(AppSpacing.radiusFull),
                  border: Border.all(
                      color: AppColors.sevHigh.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const _PulsingDot(color: AppColors.sevHigh),
                    const SizedBox(width: 6),
                    Text(
                      '$activeHigh crítico${activeHigh > 1 ? 's' : ''}',
                      style: AppTypography.caption.copyWith(
                          color: AppColors.sevHigh,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),

            const SizedBox(width: 8),
            // Refresh
            GestureDetector(
              onTap: () => context.read<MapBloc>().add(MapRefresh()),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.bg2,
                  borderRadius:
                      BorderRadius.circular(AppSpacing.radiusSm),
                  border: Border.all(color: AppColors.border),
                ),
                child: state is MapLoading
                    ? const Center(
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.brandPrimary),
                        ),
                      )
                    : const Icon(Icons.refresh_rounded,
                        size: 18, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeverityFilters(MapState state) {
    final current =
        state is MapLoaded ? state.severityFilter : null;
    final severities = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];

    return Positioned(
      top: MediaQuery.of(context).padding.top + 80,
      left: AppSpacing.lg,
      child: Row(
        children: [
          _FilterChip(
            label: 'Todos',
            active: current == null,
            onTap: () => context
                .read<MapBloc>()
                .add(MapFilterBySeverity(null)),
          ),
          const SizedBox(width: 6),
          ...severities.map((sev) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _FilterChip(
                  label: _sevLabel(sev),
                  active: current == sev,
                  color: AppColors.bySeverity(sev),
                  onTap: () => context
                      .read<MapBloc>()
                      .add(MapFilterBySeverity(current == sev ? null : sev)),
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Positioned(
      right: AppSpacing.lg,
      bottom: _selectedEvent != null ? 320 : 180,
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.bgSheet,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('LEGENDA', style: AppTypography.label),
            const SizedBox(height: 8),
            ...['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'].map((sev) {
              final color = AppColors.bySeverity(sev);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(_sevLabel(sev),
                        style: AppTypography.caption
                            .copyWith(color: color)),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildEventSheet(FloodEvent event) {
    final color = AppColors.bySeverity(event.severity);

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.bgSheet,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: color.withValues(alpha: 0.4), width: 1.5)),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.15),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SeverityBadge(severity: event.severity),
                      const Spacer(),
                      GestureDetector(
                        onTap: () =>
                            setState(() => _selectedEvent = null),
                        child: const Icon(Icons.close_rounded,
                            size: 20, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(event.regionName, style: AppTypography.h3),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Detectado em ${DateFormat('dd/MM/yyyy HH:mm').format(event.detectedAt)}',
                    style: AppTypography.caption,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    children: [
                      Expanded(
                        child: StatChip(
                          label: 'ÁREA INUNDADA',
                          value: event.formattedArea,
                          valueColor: color,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: StatChip(
                          label: 'CONFIANÇA',
                          value: event.confidenceLabel,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: StatChip(
                          label: 'SATÉLITE',
                          value: 'SAR',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapControl(
      {required IconData icon,
      required VoidCallback onTap,
      bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: active ? AppColors.brandGlow : AppColors.bg2,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(
              color: active ? AppColors.brandPrimary : AppColors.border),
        ),
        child: Icon(icon,
            size: 20,
            color:
                active ? AppColors.brandPrimary : AppColors.textSecondary),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Positioned(
      bottom: 80,
      left: AppSpacing.lg,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.bg2,
          borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.brandPrimary),
            ),
            const SizedBox(width: 8),
            Text('Atualizando dados...',
                style: AppTypography.caption
                    .copyWith(color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    return Positioned(
      bottom: 80,
      left: AppSpacing.lg,
      right: AppSpacing.lg,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.sevHighBg,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.sevHigh.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                size: 16, color: AppColors.sevHigh),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: AppTypography.caption
                      .copyWith(color: AppColors.sevHigh)),
            ),
            GestureDetector(
              onTap: () =>
                  context.read<MapBloc>().add(MapLoadEvents()),
              child: Text('Tentar',
                  style: AppTypography.caption
                      .copyWith(color: AppColors.brandPrimary)),
            ),
          ],
        ),
      ),
    );
  }

  IconData _severityIcon(String severity) {
    switch (severity.toUpperCase()) {
      case 'LOW':
        return Icons.info_outline_rounded;
      case 'MEDIUM':
        return Icons.warning_amber_rounded;
      case 'HIGH':
        return Icons.dangerous_outlined;
      case 'CRITICAL':
        return Icons.crisis_alert_rounded;
      default:
        return Icons.water_drop_outlined;
    }
  }

  String _sevLabel(String sev) {
    switch (sev) {
      case 'LOW':
        return 'Baixo';
      case 'MEDIUM':
        return 'Médio';
      case 'HIGH':
        return 'Alto';
      case 'CRITICAL':
        return 'Crítico';
      default:
        return sev;
    }
  }
}

// ── FilterChip interno ────────────────────────────────────────
class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final Color? color;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.active,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.brandPrimary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? c.withValues(alpha: 0.2) : AppColors.bg2.withValues(alpha: 0.9),
          borderRadius:
              BorderRadius.circular(AppSpacing.radiusFull),
          border: Border.all(
            color: active ? c : AppColors.border,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: AppTypography.caption.copyWith(
            color: active ? c : AppColors.textSecondary,
            fontWeight:
                active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// ── Pulsing dot ──────────────────────────────────────────────
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: _ctrl.value * 0.8),
              blurRadius: _ctrl.value * 6,
            ),
          ],
        ),
      ),
    );
  }
}
