import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/config/tiles_em_cache.dart';

void main() {
  test("TileLayer aceita o provedor de cache", () {
    expect(
      () => TileLayer(
        urlTemplate: 'https://exemplo.com/{z}/{x}/{y}.png',
        userAgentPackageName: 'br.com.aqualerta',
        tileProvider: TilesEmCache(),
      ),
      returnsNormally,
    );
  });
}
