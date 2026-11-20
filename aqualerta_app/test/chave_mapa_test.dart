import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aqualerta/core/config/chave_mapa.dart';
import 'package:aqualerta/core/config/mapas.dart';

void main() {
  setUp(() {
    FundoMapa.chaveRemota.value = null;
    FundoMapa.chaveDeTeste = null;
  });
  tearDown(() {
    ChaveMapa.buscarParaTeste = null;
    FundoMapa.chaveRemota.value = null;
  });

  test('a chave do servidor liga o MapTiler e fica guardada', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    ChaveMapa.buscarParaTeste = () async => 'Abc123Def456';
    await ChaveMapa.carregar(prefs: p);
    expect(FundoMapa.temMapTiler, isTrue);
    expect(p.getString('chave_mapa_v1'), 'Abc123Def456');
  });

  test('sem internet: usa a chave guardada da última vez', () async {
    SharedPreferences.setMockInitialValues({'chave_mapa_v1': 'Guardada12345'});
    final p = await SharedPreferences.getInstance();
    ChaveMapa.buscarParaTeste = () async => throw Exception('sem rede');
    await ChaveMapa.carregar(prefs: p);
    expect(FundoMapa.chaveRemota.value, 'Guardada12345');
  });

  test('servidor sem chave: volta para os mapas gratuitos e esquece a guardada',
      () async {
    SharedPreferences.setMockInitialValues({'chave_mapa_v1': 'Guardada12345'});
    final p = await SharedPreferences.getInstance();
    ChaveMapa.buscarParaTeste = () async => null;
    await ChaveMapa.carregar(prefs: p);
    expect(FundoMapa.chaveRemota.value, isNull);
    expect(p.getString('chave_mapa_v1'), isNull);
  });

  test('resposta estranha não vira chave', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    ChaveMapa.buscarParaTeste = () async => '<html>erro</html>';
    await ChaveMapa.carregar(prefs: p);
    expect(FundoMapa.chaveRemota.value, isNull);
    expect(ChaveMapa.valida('abc'), isFalse);
    expect(ChaveMapa.valida('Abc123Def456'), isTrue);
  });
}
