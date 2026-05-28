import 'package:equatable/equatable.dart';

class FloodEvent extends Equatable {
  final String id;
  final String regionId;
  final String regionName;
  final DateTime detectedAt;
  final double floodedAreaKm2;
  final String severity; // LOW, MEDIUM, HIGH, CRITICAL
  final double confidence;
  final double? centerLat;
  final double? centerLng;
  final String? geojsonPath;
  final String satelliteType;
  final List<FloodPolygon> polygons;

  const FloodEvent({
    required this.id,
    required this.regionId,
    required this.regionName,
    required this.detectedAt,
    required this.floodedAreaKm2,
    required this.severity,
    required this.confidence,
    this.centerLat,
    this.centerLng,
    this.geojsonPath,
    this.satelliteType = 'SENTINEL_1_SAR',
    this.polygons = const [],
  });

  @override
  List<Object?> get props => [id];

  String get formattedArea {
    if (floodedAreaKm2 < 1) return '${(floodedAreaKm2 * 100).toStringAsFixed(0)} ha';
    return '${floodedAreaKm2.toStringAsFixed(1)} km²';
  }

  String get confidenceLabel => '${(confidence * 100).toStringAsFixed(0)}%';
}

class FloodPolygon extends Equatable {
  final List<List<double>> coordinates;
  final double areaKm2;
  final String severity;

  const FloodPolygon({
    required this.coordinates,
    required this.areaKm2,
    required this.severity,
  });

  @override
  List<Object?> get props => [coordinates];
}
