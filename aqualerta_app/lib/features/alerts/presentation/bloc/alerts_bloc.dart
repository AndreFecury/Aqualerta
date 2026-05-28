import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:aqualerta/features/alerts/domain/entities/alert.dart';
import 'package:aqualerta/features/alerts/data/datasources/alerts_remote_datasource.dart';

// ── Events ──────────────────────────────────────────────────
abstract class AlertsEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class AlertsLoad extends AlertsEvent {}

class AlertsRefresh extends AlertsEvent {}

class AlertsFilterChanged extends AlertsEvent {
  final String? severity;
  final String? status;
  AlertsFilterChanged({this.severity, this.status});
  @override
  List<Object?> get props => [severity, status];
}

class AlertAcknowledge extends AlertsEvent {
  final String alertId;
  AlertAcknowledge(this.alertId);
  @override
  List<Object?> get props => [alertId];
}

// ── States ───────────────────────────────────────────────────
abstract class AlertsState extends Equatable {
  @override
  List<Object?> get props => [];
}

class AlertsInitial extends AlertsState {}

class AlertsLoading extends AlertsState {}

class AlertsLoaded extends AlertsState {
  final List<Alert> allAlerts;
  final List<Alert> filteredAlerts;
  final String? severityFilter;
  final String? statusFilter;
  final int activeCount;

  AlertsLoaded({
    required this.allAlerts,
    required this.filteredAlerts,
    this.severityFilter,
    this.statusFilter,
    required this.activeCount,
  });

  AlertsLoaded copyWith({
    List<Alert>? allAlerts,
    List<Alert>? filteredAlerts,
    String? severityFilter,
    String? statusFilter,
  }) {
    return AlertsLoaded(
      allAlerts: allAlerts ?? this.allAlerts,
      filteredAlerts: filteredAlerts ?? this.filteredAlerts,
      severityFilter: severityFilter,
      statusFilter: statusFilter,
      activeCount: (allAlerts ?? this.allAlerts)
          .where((a) => a.isActive)
          .length,
    );
  }

  @override
  List<Object?> get props => [allAlerts, severityFilter, statusFilter];
}

class AlertsError extends AlertsState {
  final String message;
  AlertsError(this.message);
  @override
  List<Object?> get props => [message];
}

// ── BLoC ─────────────────────────────────────────────────────
class AlertsBloc extends Bloc<AlertsEvent, AlertsState> {
  final AlertsRemoteDatasource _datasource;

  AlertsBloc(this._datasource) : super(AlertsInitial()) {
    on<AlertsLoad>(_onLoad);
    on<AlertsRefresh>(_onRefresh);
    on<AlertsFilterChanged>(_onFilter);
    on<AlertAcknowledge>(_onAcknowledge);
  }

  Future<void> _onLoad(AlertsLoad event, Emitter<AlertsState> emit) async {
    emit(AlertsLoading());
    await _fetch(emit);
  }

  Future<void> _onRefresh(AlertsRefresh event, Emitter<AlertsState> emit) async {
    await _fetch(emit);
  }

  Future<void> _fetch(Emitter<AlertsState> emit,
      {String? severity, String? status}) async {
    try {
      final current = state is AlertsLoaded ? state as AlertsLoaded : null;
      final sev = severity ?? current?.severityFilter;
      final sta = status ?? current?.statusFilter;

      final alerts = await _datasource.getAlerts(
        severityFilter: sev,
        statusFilter: sta,
      );

      final activeCount = alerts.where((a) => a.isActive).length;

      emit(AlertsLoaded(
        allAlerts: alerts,
        filteredAlerts: alerts,
        severityFilter: sev,
        statusFilter: sta,
        activeCount: activeCount,
      ));
    } catch (e) {
      emit(AlertsError('Falha ao carregar alertas: $e'));
    }
  }

  void _onFilter(AlertsFilterChanged event, Emitter<AlertsState> emit) {
    add(AlertsLoad());
  }

  Future<void> _onAcknowledge(
      AlertAcknowledge event, Emitter<AlertsState> emit) async {
    try {
      await _datasource.acknowledgeAlert(event.alertId);
      if (state is AlertsLoaded) {
        final loaded = state as AlertsLoaded;
        final updated = loaded.allAlerts
            .map((a) => a.id == event.alertId
                ? Alert(
                    id: a.id,
                    regionId: a.regionId,
                    regionName: a.regionName,
                    title: a.title,
                    body: a.body,
                    severity: a.severity,
                    status: a.status,
                    issuedAt: a.issuedAt,
                    resolvedAt: a.resolvedAt,
                    floodEventId: a.floodEventId,
                    acknowledged: true,
                  )
                : a)
            .toList();
        emit(loaded.copyWith(allAlerts: updated, filteredAlerts: updated));
      }
    } catch (_) {}
  }
}
