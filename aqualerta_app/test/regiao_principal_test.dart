import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';

const _pvh = Regiao(
    id: 'pvh', nome: 'Porto Velho', uf: 'RO', centro: LatLng(-8.76, -63.9));
const _manaus =
    Regiao(id: 'mao', nome: 'Manaus', uf: 'AM', centro: LatLng(-3.1, -60.0));
const _parintins =
    Regiao(id: 'pin', nome: 'Parintins', uf: 'AM', centro: LatLng(-2.6, -56.7));

AlertaV3 _alerta(String regiao, Severidade s) => AlertaV3(
      id: 'a-$regiao',
      regiaoId: regiao,
      regiaoNome: regiao,
      titulo: 't',
      texto: 'x',
      severidadeOriginal: s,
      ativo: true,
      emitidoEm: DateTime(2026, 11, 18),
    );

void main() {
  test('todos os rios baixos: abre em Manaus, não na primeira da lista', () {
    const p = Painel(regioes: [_pvh, _parintins, _manaus]);
    expect(p.regiaoPrincipal?.id, 'mao');
  });

  test('a região de maior risco vence Manaus', () {
    final p = Painel(
        regioes: const [_manaus, _pvh, _parintins],
        alertas: [_alerta('pin', Severidade.alto)]);
    expect(p.regiaoPrincipal?.id, 'pin');
  });

  test('empate em risco médio também fica com Manaus', () {
    final p = Painel(regioes: const [
      _pvh,
      _manaus
    ], alertas: [
      _alerta('pvh', Severidade.medio),
      _alerta('mao', Severidade.medio),
    ]);
    expect(p.regiaoPrincipal?.id, 'mao');
  });

  test('a região seguida vem antes de tudo', () {
    final p = Painel(
        regioes: const [_manaus, _pvh, _parintins],
        seguidas: const {'pvh'},
        alertas: [_alerta('pin', Severidade.critico)]);
    expect(p.regiaoPrincipal?.id, 'pvh');
  });
}
