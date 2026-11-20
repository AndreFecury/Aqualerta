import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aqualerta/app/router.dart' show indiceDaAba;
import 'package:aqualerta/app/voltar.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/features/settings/presentation/screens/perfil_screen.dart';

import 'telas_v3_test.dart' show montar;

const _rioBranco = Regiao(
    id: 'rbr', nome: 'Rio Branco', uf: 'AC', centro: LatLng(-9.97, -67.81));
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
      emitidoEm: DateTime(2026, 11, 20),
    );

void main() {
  group('onde o mapa abre', () {
    final painel = Painel(
      regioes: const [_parintins, _rioBranco, _manaus],
      seguidas: const {'pin'},
      alertas: [_alerta('rbr', Severidade.alto)],
    );

    test('padrão: Manaus, mesmo com Rio Branco em risco alto e outra seguida',
        () {
      expect(const ExibicaoMapa().inicio, InicioMapa.manaus);
      expect(painel.regiaoInicial(InicioMapa.manaus)?.id, 'mao');
    });

    test('"Região que sigo" abre na seguida; sem seguida, em Manaus', () {
      expect(painel.regiaoInicial(InicioMapa.seguida)?.id, 'pin');
      final semSeguida =
          Painel(regioes: const [_rioBranco, _manaus], alertas: const []);
      expect(semSeguida.regiaoInicial(InicioMapa.seguida)?.id, 'mao');
    });

    test('"Maior risco" abre onde o risco é maior', () {
      expect(painel.regiaoInicial(InicioMapa.maiorRisco)?.id, 'rbr');
    });

    test('a escolha fica guardada no aparelho', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      await CamadasCubit(p).escolherInicio(InicioMapa.maiorRisco);
      expect(CamadasCubit(p).state.inicio, InicioMapa.maiorRisco);
    });

    testWidgets('Perfil tem "Abrir o mapa em" e troca a escolha', (t) async {
      await montar(t, const PerfilScreen());
      final opcao = find.text('Região que sigo');
      await t.scrollUntilVisible(opcao, 200);
      expect(find.text('Abrir o mapa em'), findsOneWidget);
      expect(find.text('O mapa sempre abre em Manaus.'), findsOneWidget);
      await t.tap(opcao);
      await t.pumpAndSettle();
      expect(find.textContaining('primeira região que você segue'),
          findsOneWidget);
    });
  });

  group('botão voltar', () {
    setUp(() => FundoMapa.desligado = true);

    test('pergunta primeiro a última tela registrada', () {
      final ordem = <String>[];
      bool a() {
        ordem.add('a');
        return false;
      }

      bool b() {
        ordem.add('b');
        return true;
      }

      Voltar.registrar(a);
      Voltar.registrar(b);
      expect(Voltar.tratar(), isTrue);
      expect(ordem, ['b']);
      Voltar.remover(b);
      expect(Voltar.tratar(), isFalse);
      Voltar.remover(a);
    });

    test('ordem das abas no menu', () {
      expect(indiceDaAba('/map'), 0);
      expect(indiceDaAba('/alerts/123'), 1);
      expect(indiceDaAba('/rios'), 2);
      expect(indiceDaAba('/perfil'), 3);
    });

    testWidgets('no Mapa: primeiro limpa a busca, depois não há o que desfazer',
        (t) async {
      await montar(t, const MapaScreen());
      await t.enterText(find.byType(TextField), 'compensa');
      await t.pump();
      expect(Voltar.tratar(), isTrue);
      await t.pump();
      expect(find.text('compensa'), findsNothing);
      expect(Voltar.tratar(), isFalse,
          reason: 'sem busca nem região escolhida: o app decide (sair)');
    });
  });
}
