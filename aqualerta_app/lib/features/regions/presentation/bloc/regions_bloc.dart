import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:aqualerta/features/regions/domain/entities/monitored_region.dart';
import 'package:aqualerta/features/regions/data/datasources/regions_remote_datasource.dart';

// ── Events ──────────────────────────────────────────────────
abstract class RegionsEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class RegionsLoad extends RegionsEvent {}

class RegionsSubscribe extends RegionsEvent {
  final String regionId;
  RegionsSubscribe(this.regionId);
  @override
  List<Object?> get props => [regionId];
}

class RegionsUnsubscribe extends RegionsEvent {
  final String regionId;
  RegionsUnsubscribe(this.regionId);
  @override
  List<Object?> get props => [regionId];
}

class RegionsUpdateNotification extends RegionsEvent {
  final String regionId;
  final bool notify;
  final String minSeverity;
  RegionsUpdateNotification(this.regionId, this.notify, this.minSeverity);
  @override
  List<Object?> get props => [regionId, notify, minSeverity];
}

// ── States ───────────────────────────────────────────────────
abstract class RegionsState extends Equatable {
  @override
  List<Object?> get props => [];
}

class RegionsInitial extends RegionsState {}

class RegionsLoading extends RegionsState {}

class RegionsLoaded extends RegionsState {
  final List<MonitoredRegion> subscribedRegions;
  final List<MonitoredRegion> publicRegions;

  RegionsLoaded({
    required this.subscribedRegions,
    required this.publicRegions,
  });

  List<MonitoredRegion> get availableToSubscribe => publicRegions
      .where((r) => !subscribedRegions.any((s) => s.id == r.id))
      .toList();

  @override
  List<Object?> get props => [subscribedRegions, publicRegions];
}

class RegionsError extends RegionsState {
  final String message;
  RegionsError(this.message);
  @override
  List<Object?> get props => [message];
}

// ── BLoC ─────────────────────────────────────────────────────
class RegionsBloc extends Bloc<RegionsEvent, RegionsState> {
  final RegionsRemoteDatasource _datasource;

  RegionsBloc(this._datasource) : super(RegionsInitial()) {
    on<RegionsLoad>(_onLoad);
    on<RegionsSubscribe>(_onSubscribe);
    on<RegionsUnsubscribe>(_onUnsubscribe);
    on<RegionsUpdateNotification>(_onUpdateNotif);
  }

  Future<void> _onLoad(RegionsLoad event, Emitter<RegionsState> emit) async {
    emit(RegionsLoading());
    try {
      final subscribed = await _datasource.getUserRegions();
      final publicRegions = await _datasource.getPublicRegions();
      emit(RegionsLoaded(
        subscribedRegions: subscribed,
        publicRegions: publicRegions,
      ));
    } catch (e) {
      emit(RegionsError('Falha ao carregar regiões: $e'));
    }
  }

  Future<void> _onSubscribe(
      RegionsSubscribe event, Emitter<RegionsState> emit) async {
    try {
      await _datasource.subscribeToRegion(event.regionId);
      add(RegionsLoad());
    } catch (e) {
      emit(RegionsError('Falha ao monitorar região: $e'));
    }
  }

  Future<void> _onUnsubscribe(
      RegionsUnsubscribe event, Emitter<RegionsState> emit) async {
    try {
      await _datasource.unsubscribeFromRegion(event.regionId);
      add(RegionsLoad());
    } catch (e) {
      emit(RegionsError('Falha ao remover monitoramento: $e'));
    }
  }

  Future<void> _onUpdateNotif(
      RegionsUpdateNotification event, Emitter<RegionsState> emit) async {
    try {
      await _datasource.updateNotificationPreference(
          event.regionId, event.notify, event.minSeverity);
      add(RegionsLoad());
    } catch (e) {
      emit(RegionsError('Falha ao atualizar notificações: $e'));
    }
  }
}
