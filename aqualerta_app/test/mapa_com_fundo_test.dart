import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'telas_v3_test.dart' show montar;

void main() {
  testWidgets('mapa com o fundo ligado monta sem erro', (t) async {
    FundoMapa.desligado = false;
    await montar(t, const MapaScreen());
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    final e = t.takeException();
    FundoMapa.desligado = true;
    expect(e, isNull);
  });
}
