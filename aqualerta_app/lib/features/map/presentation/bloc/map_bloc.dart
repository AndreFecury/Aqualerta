import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:aqualerta/features/map/domain/entities/flood_event.dart';
import 'package:aqualerta/features/map/data/datasources/map_remote_datasource.dart';

// ── Events ──────────────────────────────────────────────────
abstract class MapEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class MapLoadEvents extends MapEvent {}

class MapRefresh extends MapEvent {}

class MapFilterBySeverity extends MapEvent {
  final String? severity;
  MapFilterBySeverity(this.severity);
  @override
  List<Object?> get props => [severity];
}

class MapEventReceived extends MapEvent {
  final List<FloodEvent> events;
  MapEventReceived(this.events);
  @override
  List<Object?> get props => [events];
}

// ── States ───────────────────────────────────────────────────
abstract class MapState extends Equatable {
  @override
  List<Object?> get props => [];
}

class MapInitial extends MapState {}

class MapLoading extends MapState {}

class MapLoaded extends MapState {
  final List<FloodEvent> allEvents;
  final List<FloodEvent> filteredEvents;
  final String? severityFilter;
  final DateTime loadedAt;

  MapLoaded({
    required this.allEvents,
    required this.filteredEvents,
    this.severityFilter,
    DateTime? loadedAt,
  }) : loadedAt = loadedAt ?? DateTime.now();

  MapLoaded copyWith({
    List<FloodEvent>? allEvents,
    List<FloodEvent>? filteredEvents,
    String? severityFilter,
  }) {
    return MapLoaded(
      allEvents: allEvents ?? this.allEvents,
      filteredEvents: filteredEvents ?? this.filteredEvents,
      severityFilter: severityFilter,
      loadedAt: loadedAt,
    );
  }

  @override
  List<Object?> get props => [allEvents, severityFilter, loadedAt];
}

class MapError extends MapState {
  final String message;
  MapError(this.message);
  @override
  List<Object?> get props => [message];
}

// ── BLoC ─────────────────────────────────────────────────────
class MapBloc extends Bloc<MapEvent, MapState> {
  final MapRemoteDatasource _datasource;

  MapBloc(this._datasource) : super(MapInitial()) {
    on<MapLoadEvents>(_onLoad);
    on<MapRefresh>(_onRefresh);
    on<MapFilterBySeverity>(_onFilter);
    on<MapEventReceived>(_onReceived);
  }

  Future<void> _onLoad(MapLoadEvents event, Emitter<MapState> emit) async {
    emit(MapLoading());
    await _fetch(emit);
  }

  Future<void> _onRefresh(MapRefresh event, Emitter<MapState> emit) async {
    await _fetch(emit, keepCurrent: true);
  }

  Future<void> _fetch(Emitter<MapState> emit, {bool keepCurrent = false}) async {
    try {
      final events = await _datasource.getRecentFloodEvents();
      final current = state is MapLoaded ? state as MapLoaded : null;
      final filter = current?.severityFilter;
      final filtered = filter == null
          ? events
          : events.where((e) => e.severity == filter).toList();

      emit(MapLoaded(
        allEvents: events,
        filteredEvents: filtered,
        severityFilter: filter,
      ));
    } catch (e) {
      if (!keepCurrent || state is! MapLoaded) {
        emit(MapError('Falha ao carregar eventos: $e'));
      }
    }
  }

  void _onFilter(MapFilterBySeverity event, Emitter<MapState> emit) {
    if (state is! MapLoaded) return;
    final loaded = state as MapLoaded;
    final filtered = event.severity == null
        ? loaded.allEvents
        : loaded.allEvents
            .where((e) => e.severity == event.severity)
            .toList();
    emit(loaded.copyWith(
      filteredEvents: filtered,
      severityFilter: event.severity,
    ));
  }

  void _onReceived(MapEventReceived event, Emitter<MapState> emit) {
    final current = state is MapLoaded ? state as MapLoaded : null;
    final filter = current?.severityFilter;
    final filtered = filter == null
        ? event.events
        : event.events.where((e) => e.severity == filter).toList();
    emit(MapLoaded(
      allEvents: event.events,
      filteredEvents: filtered,
      severityFilter: filter,
    ));
  }
}
