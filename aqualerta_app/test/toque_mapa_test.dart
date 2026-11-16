import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:aqualerta/core/domain/carta.dart';

Regiao _r(String id, double lado, {double? area}) => Regiao(
      id: id,
      nome: id,
      uf: 'AM',
      contornos: [
        [LatLng(0, 0), LatLng(0, lado), LatLng(lado, lado), LatLng(lado, 0)]
      ],
      areaKm2: area,
    );

void main() {
  test('pontoNoAnel separa dentro e fora', () {
    final anel = [LatLng(0, 0), LatLng(0, 2), LatLng(2, 2), LatLng(2, 0)];
    expect(pontoNoAnel(LatLng(1, 1), anel), isTrue);
    expect(pontoNoAnel(LatLng(3, 1), anel), isFalse);
  });

  test('regiaoNoPonto devolve a menor região que contém o toque', () {
    final grande = _r('grande', 10, area: 100);
    final pequena = _r('pequena', 2, area: 4);
    expect(regiaoNoPonto(LatLng(1, 1), [grande, pequena])?.id, 'pequena');
    expect(regiaoNoPonto(LatLng(5, 5), [grande, pequena])?.id, 'grande');
    expect(regiaoNoPonto(LatLng(20, 20), [grande, pequena]), isNull);
  });
}
