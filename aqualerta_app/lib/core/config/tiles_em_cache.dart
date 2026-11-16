import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';

/// Guarda os pedaços do mapa no aparelho. Quem já passou por uma região vê o
/// mapa na hora, sem esperar a rede, e o app gasta menos internet.
class TilesEmCache extends TileProvider {
  TilesEmCache({super.headers});

  static final _gerenciador = CacheManager(Config(
    'mapa_tiles',
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 8000,
  ));

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      CachedNetworkImageProvider(
        getTileUrl(coordinates, options),
        cacheManager: _gerenciador,
        headers: headers,
      );
}
