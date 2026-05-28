import 'package:equatable/equatable.dart';

class MonitoredRegion extends Equatable {
  final String id;
  final String name;
  final String? description;
  final double centerLat;
  final double centerLng;
  final double areaKm2;
  final String stateCode;
  final String? municipality;
  final bool isPublic;
  final bool userSubscribed;
  final bool notificationsEnabled;
  final String minSeverity;
  final int activeAlertsCount;
  final DateTime? lastEventAt;
  final String? lastSeverity;

  const MonitoredRegion({
    required this.id,
    required this.name,
    this.description,
    required this.centerLat,
    required this.centerLng,
    required this.areaKm2,
    required this.stateCode,
    this.municipality,
    this.isPublic = true,
    this.userSubscribed = false,
    this.notificationsEnabled = true,
    this.minSeverity = 'MEDIUM',
    this.activeAlertsCount = 0,
    this.lastEventAt,
    this.lastSeverity,
  });

  bool get hasActiveAlerts => activeAlertsCount > 0;

  @override
  List<Object?> get props => [id];
}
