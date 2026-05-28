import 'package:equatable/equatable.dart';

class Alert extends Equatable {
  final String id;
  final String regionId;
  final String regionName;
  final String title;
  final String body;
  final String severity;
  final String status; // ACTIVE, RESOLVED, SUPERSEDED
  final DateTime issuedAt;
  final DateTime? resolvedAt;
  final String? floodEventId;
  final double? floodedAreaKm2;
  final double? centerLat;
  final double? centerLng;
  final bool acknowledged;

  const Alert({
    required this.id,
    required this.regionId,
    required this.regionName,
    required this.title,
    required this.body,
    required this.severity,
    required this.status,
    required this.issuedAt,
    this.resolvedAt,
    this.floodEventId,
    this.floodedAreaKm2,
    this.centerLat,
    this.centerLng,
    this.acknowledged = false,
  });

  bool get isActive => status == 'ACTIVE';

  @override
  List<Object?> get props => [id];
}
