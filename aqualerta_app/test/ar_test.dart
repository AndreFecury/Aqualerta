import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/features/map/data/ar_repository.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';
import 'package:aqualerta/features/settings/presentation/screens/perfil_screen.dart';

import 'telas_v3_test.dart' show montar, ArFixo;

/// Linha como a RPC ar_resumo devolve (valores do teste SQL com dados reais
/// de Manaus em 21/11/2026: IQAr 54, MP2,5 de 27,3 µg/m³).
Map<String, dynamic> _linha(
        {int? iqar = 54, bool fumaca = false, int focos = 0}) =>
    {
      'region_id': 'r-compensa',
      'hora': '2026-11-21T21:00:00+00:00',
      'iqar': iqar,
      'nivel': iqar == null ? null : 'N2',
      'poluente': 'pm2_5',
      'pm2_5_24': 27.3,
      'iqar_previsto_48h': 55,
      'hora_pior_prevista': '2026-11-22T22:00:00+00:00',
      'tendencia': 'estavel',
      'focos_24h': focos,
      'fumaca_provavel': fumaca,
      'atualizado_em': DateTime.now().toUtc().toIso8601String(),
    };

Finder _rolavel() => find
    .descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable))
    .first;

void main() {
  group('Domínio', () {
    test('níveis do IQAr nas fronteiras do MMA', () {
      expect(NivelAr.doIndice(40), NivelAr.n1);
      expect(NivelAr.doIndice(41), NivelAr.n2);
      expect(NivelAr.doIndice(80), NivelAr.n2);
      expect(NivelAr.doIndice(81), NivelAr.n3);
      expect(NivelAr.doIndice(121), NivelAr.n4);
      expect(NivelAr.doIndice(201), NivelAr.n5);
      expect(NivelAr.n1.saude, isNull,
          reason: 'nunca "ar excelente" por modelo');
      expect(NivelAr.n2.saude, contains('Crianças, idosos'));
      expect(NivelAr.doAviso(Severidade.alto), NivelAr.n4);
      expect(NivelAr.doAviso(Severidade.critico), NivelAr.n5);
    });

    test('lê a linha da RPC', () {
      final r = ResumoAr.doJson(_linha(fumaca: true, focos: 12));
      expect(r.iqar, 54);
      expect(r.nivel, NivelAr.n2);
      expect(r.pm25Media24h, 27.3);
      expect(r.previsto48h, 55);
      expect(r.tendencia, TendenciaAr.estavel);
      expect(r.fumacaProvavel, isTrue);
      expect(r.focos24h, 12);
      expect(ResumoAr.doJson(_linha(iqar: null)).nivel, isNull);
    });

    test('paleta do ar não usa as cores de cheia', () {
      const cheia = [0xFF2E7D4F, 0xFFE3A600, 0xFFE0661B, 0xFFC1121F];
      for (final n in NivelAr.values) {
        expect(cheia, isNot(contains(n.corClara.toARGB32())));
      }
    });

    test('aviso de ar não muda o risco de cheia da região', () {
      final ar = AlertaV3(
        id: 'a1',
        regiaoId: 'r1',
        regiaoNome: 'Parintins, AM',
        titulo: 'Qualidade do ar muito ruim em Parintins',
        texto: 'x',
        severidadeOriginal: Severidade.alto,
        ativo: true,
        emitidoEm: DateTime(2026, 11, 21),
        origem: AlertaV3.origemAr,
      );
      expect(ar.ehAr, isTrue);
      final painel = Painel(carregando: false, alertas: [ar]);
      expect(painel.severidadeDaRegiao('r1'), Severidade.baixo);
      expect(painel.ativos, hasLength(1),
          reason: 'aparece na lista de alertas');
    });

    test('estado da fonte no Perfil', () {
      final agora = DateTime(2026, 11, 21, 12);
      expect(estadoAr(null, agora: agora), 'Aguardando');
      expect(estadoAr(agora.subtract(const Duration(hours: 2)), agora: agora),
          'Ativa');
      expect(estadoAr(agora.subtract(const Duration(hours: 4)), agora: agora),
          'Atrasada');
    });
  });

  group('ArCubit', () {
    test('guarda em memória por 30 min e busca de novo depois', () async {
      var agora = DateTime(2026, 11, 21, 12);
      final fonte = ArFixo([ResumoAr.doJson(_linha())], agora);
      final cubit = ArCubit(fonte, relogio: () => agora);
      await cubit.carregar();
      await cubit.carregar();
      expect(fonte.chamadas, 1);
      expect(cubit.state.de('r-compensa')!.iqar, 54);
      expect(cubit.state.coletaEm, agora);
      agora = agora.add(ArCubit.validadeCache);
      await cubit.carregar();
      expect(fonte.chamadas, 2);
    });

    test('erro sem dados: estado de erro; com dados: mantém os antigos',
        () async {
      final fonte = ArFixo([ResumoAr.doJson(_linha())])..falhar = true;
      final cubit = ArCubit(fonte);
      await cubit.carregar();
      expect(cubit.state.situacao, SituacaoAr.erro);
      await cubit.carregar();
      expect(fonte.chamadas, 1, reason: 'erro não repete sozinho');
      fonte.falhar = false;
      await cubit.carregar(forcar: true);
      expect(cubit.state.situacao, SituacaoAr.pronto);
      fonte.falhar = true;
      await cubit.carregar(forcar: true);
      expect(cubit.state.de('r-compensa'), isNotNull);
    });
  });

  group('Bloco no cartão da região', () {
    testWidgets('mostra índice, poluente, previsão e a ressalva de modelo',
        (t) async {
      // Sensor saudável perto: sem ele a manchete vira "Sem medição agora".
      await montar(t, const MapaScreen(),
          ar: ArFixo([
            ResumoAr.doJson(_linha())
                .comContexto(ContextoAr.doJson(_contexto(ok: false)))
          ]));
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(find.text('Ar moderada · índice 54'), 200,
          scrollable: _rolavel());
      expect(find.textContaining('partículas finas (MP2,5)'), findsOneWidget);
      // A previsão numérica de 48 h está escondida (experimental).
      expect(find.textContaining('pior previsto'), findsNothing);
      expect(find.byKey(const Key('ar-previsao-experimental')), findsOneWidget);
      expect(find.textContaining('Crianças, idosos'), findsOneWidget);
      expect(find.textContaining('Estimativa de modelo, não medição local'),
          findsOneWidget);
      // Rótulo lido pelo leitor de tela (o cartão fica abaixo da dobra).
      expect(
          find.byWidgetPredicate((w) =>
              w is Semantics &&
              w.properties.label == 'Qualidade do ar moderada, índice 54'),
          findsOneWidget);
    });

    testWidgets('focos como fato separado, sem afirmar a causa', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha(fumaca: true, focos: 12))]));
      await t.pump(const Duration(milliseconds: 100));
      final focos = find
          .text('12 focos de queimada a até 100 km nas últimas 24 h (INPE).');
      await t.scrollUntilVisible(focos, 200, scrollable: _rolavel());
      expect(find.textContaining('queimadas distantes'), findsOneWidget);
      expect(find.textContaining('pode ser a causa'), findsNothing);
    });

    testWidgets('sem estimativa: diz que não há, sem inventar', (t) async {
      await montar(t, const MapaScreen(), ar: ArFixo());
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(
          find.text(
              'Sem estimativa de qualidade do ar para esta região agora.'),
          200,
          scrollable: _rolavel());
      expect(find.textContaining('índice'), findsNothing);
    });

    testWidgets('erro: botão de tentar de novo busca outra vez', (t) async {
      // Sensor saudável perto (a manchete com a categoria só vale com medição).
      final fonte = ArFixo([
        ResumoAr.doJson(_linha())
            .comContexto(ContextoAr.doJson(_contexto(ok: false)))
      ])
        ..falhar = true;
      await montar(t, const MapaScreen(), ar: fonte);
      await t.pump(const Duration(milliseconds: 100));
      final botao = find.text('Tentar de novo');
      await t.scrollUntilVisible(
          find.text('Não foi possível carregar a qualidade do ar.'), 200,
          scrollable: _rolavel());
      fonte.falhar = false;
      // O botão fica abaixo da dobra do cartão arrastável: aciona direto.
      t
          .widget<TextButton>(
              find.ancestor(of: botao.last, matching: find.byType(TextButton)))
          .onPressed!();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Ar moderada · índice 54'), findsOneWidget);
    });
  });

  group('Camada no mapa', () {
    setUp(() => FundoMapa.desligado = true);
    const ligada = {
      'mapa.camadas': ['regioes', 'qualidadeAr'],
    };

    testWidgets('desligada por padrão: sem selo e sem legenda', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha())]));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('selo-ar-r-compensa')), findsNothing);
      expect(find.textContaining('Ar (modelo)'), findsNothing);
    });

    testWidgets(
        'ligada: selo com número e nível no marcador, sem pintar o município, '
        'legenda com as faixas', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha())]), preferencias: ligada);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('selo-ar-r-compensa')),
              matching: find.text('Ar 54 · Moderada')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('camada-ar')), findsNothing,
          reason: 'o valor é de um ponto da grade, não do município');
      expect(find.text('Boa · 0 a 40'), findsOneWidget);
      expect(find.text('Péssima · acima de 200'), findsOneWidget);
      for (final n in NivelAr.values) {
        expect(find.byKey(ValueKey('legenda-ar-${n.name}')), findsOneWidget);
      }
    });

    testWidgets('"Boa" com cautela vira "Boa (estimativa)" no selo', (t) async {
      final r = ResumoAr.doJson(_linha(iqar: 30)).comContexto(
          ContextoAr.doJson(_contexto(semSensor: true, cautela: true)));
      await montar(t, const MapaScreen(),
          ar: ArFixo([r]), preferencias: ligada);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Ar 30 · Boa (estimativa)'), findsOneWidget);
    });

    testWidgets('sem estimativa: o selo diz isso', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha(iqar: null))]),
          preferencias: ligada);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Ar sem estimativa'), findsOneWidget);
      expect(find.text('Ar (modelo) · sem estimativa'), findsOneWidget);
    });

    testWidgets('erro de rede: a legenda diz que não carregou', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo()..falhar = true,
          preferencias: {
            'mapa.camadas': ['qualidadeAr'],
          });
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Ar (modelo) · não carregou'), findsOneWidget);
    });

    testWidgets('painel de exibição liga a camada e guarda a escolha',
        (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha())]));
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(
          find.bySemanticsLabel('Exibição do mapa: tipo de mapa e camadas'));
      await t.pumpAndSettle();
      final item = find.descendant(
          of: find.byType(BottomSheet), matching: find.text('Qualidade do ar'));
      await t.ensureVisible(item);
      await t.pumpAndSettle();
      await t.tap(item);
      await t.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('mapa.camadas'), contains('qualidadeAr'));
    });
  });

  group('Sensor perto e cautela (Fase 4)', () {
    test('lê o contexto da RPC', () {
      final c = ContextoAr.doJson(_contexto());
      expect(c.comparacaoOk, isTrue);
      expect(c.sensorNivel, NivelAr.n4);
      expect(c.modeloNivel, NivelAr.n2);
      expect(c.fraseComparacao,
          'Sensor perto: Muito ruim (80 µg/m³). Modelo: Moderada');
      expect(c.fraseDivergencia, contains('sensor perto indica ar bem pior'));
      expect(ContextoAr.doJson(_contexto(ok: false)).fraseComparacao, isNull);
      expect(
          ContextoAr.doJson(_contexto(sensorPior: false, modeloPior: true))
              .fraseDivergencia,
          contains('modelo indica ar pior'));
    });

    testWidgets('cartão mostra as duas leituras, sem dizer quem acertou',
        (t) async {
      final r =
          ResumoAr.doJson(_linha()).comContexto(ContextoAr.doJson(_contexto()));
      await montar(t, const MapaScreen(), ar: ArFixo([r]));
      await t.pump(const Duration(milliseconds: 100));
      final comp = find.byKey(const Key('ar-comparacao'));
      await t.scrollUntilVisible(comp, 200, scrollable: _rolavel());
      expect(
          find.descendant(
              of: comp,
              matching: find.text(
                  'Sensor perto: Muito ruim (80 µg/m³). Modelo: Moderada.')),
          findsOneWidget);
      expect(
          find.descendant(
              of: comp,
              matching: find.textContaining('sensor perto indica ar bem pior')),
          findsOneWidget);
      expect(
          find.descendant(
              of: comp,
              matching:
                  find.textContaining('baixo custo (AirGradient, a 2 km')),
          findsOneWidget);
      expect(find.textContaining('%'), findsNothing, reason: 'sem porcentagem');
    });

    testWidgets('sensor sem dias suficientes: só diz que existe', (t) async {
      final r = ResumoAr.doJson(_linha())
          .comContexto(ContextoAr.doJson(_contexto(ok: false)));
      await montar(t, const MapaScreen(), ar: ArFixo([r]));
      await t.pump(const Duration(milliseconds: 100));
      final aviso = find.textContaining('ainda sem dias suficientes');
      await t.scrollUntilVisible(aviso, 200, scrollable: _rolavel());
      expect(find.byKey(const Key('ar-comparacao')), findsNothing);
    });

    testWidgets('região só com modelo, "Boa" com muitos focos: cautela forte',
        (t) async {
      final r = ResumoAr.doJson(_linha(iqar: 30)).comContexto(ContextoAr.doJson(
          _contexto(semSensor: true, cautela: true, focos: 900)));
      await montar(t, const MapaScreen(), ar: ArFixo([r]));
      await t.pump(const Duration(milliseconds: 100));
      final cautela = find.byKey(const Key('ar-cautela-boa'));
      await t.scrollUntilVisible(cautela, 200, scrollable: _rolavel());
      expect(find.text(textoCautelaBoa), findsOneWidget);
      expect(find.textContaining('Há um sensor perto'), findsNothing);
    });

    testWidgets('"Boa" só pela época de fumaça (poucos focos): cautela branda',
        (t) async {
      final r = ResumoAr.doJson(_linha(iqar: 30)).comContexto(
          ContextoAr.doJson(_contexto(semSensor: true, cautela: true)));
      await montar(t, const MapaScreen(), ar: ArFixo([r]));
      await t.pump(const Duration(milliseconds: 100));
      final cautela = find.byKey(const Key('ar-cautela-boa'));
      await t.scrollUntilVisible(cautela, 200, scrollable: _rolavel());
      expect(find.text(textoCautelaEpoca), findsOneWidget);
      expect(find.text(textoCautelaBoa), findsNothing);
    });

    testWidgets('com cautela mas nível Moderada: sem a frase do "Boa"',
        (t) async {
      final r = ResumoAr.doJson(_linha()).comContexto(
          ContextoAr.doJson(_contexto(semSensor: true, cautela: true)));
      await montar(t, const MapaScreen(), ar: ArFixo([r]));
      await t.pump(const Duration(milliseconds: 100));
      // Só modelo: a manchete é "Sem medição agora" e a estimativa fica rotulada.
      await t.scrollUntilVisible(find.text('Sem medição agora'), 200,
          scrollable: _rolavel());
      expect(find.byKey(const Key('ar-cautela-boa')), findsNothing);
    });
  });

  group('Perfil', () {
    test('preferência de ar: desligada por padrão, vai como ar_optin', () {
      final b = const PreferenciasNotificacao().paraBanco();
      expect(b['ar_optin'], false);
      expect(b['ar'], false);
      expect(const PreferenciasNotificacao(ar: true).paraBanco()['ar_optin'],
          true);
    });

    testWidgets('sem aviso ligado: sem chave, texto diz onde há sensor',
        (t) async {
      final r =
          ResumoAr.doJson(_linha()).comContexto(ContextoAr.doJson(_contexto()));
      await montar(t, const PerfilScreen(), ar: ArFixo([r]));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      final texto = find.byKey(const Key('avisos-ar-texto'));
      await t.scrollUntilVisible(texto, 200,
          scrollable: find.byType(Scrollable).first);
      expect(
          find.descendant(
              of: texto,
              matching: find.textContaining(
                  'Sensor de qualidade do ar perto: Compensa.')),
          findsOneWidget);
      expect(find.byKey(const Key('avisos-ar')), findsNothing);
    });

    testWidgets('com aviso ligado na região: chave aparece, desligada, e salva',
        (t) async {
      final r = ResumoAr.doJson(_linha())
          .comContexto(ContextoAr.doJson(_contexto(avisoLigado: true)));
      await montar(t, const PerfilScreen(), ar: ArFixo([r]));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      final chave = find.byKey(const Key('avisos-ar'));
      await t.scrollUntilVisible(chave, 200,
          scrollable: find.byType(Scrollable).first);
      expect(t.widget<SwitchListTile>(chave).value, isFalse);
      await t.tap(chave);
      await t.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('avisos.ar_optin'), isTrue);
    });

    testWidgets('fontes de dados listam o ar com o estado da coleta',
        (t) async {
      await montar(t, const PerfilScreen(),
          ar: ArFixo(
              const [], DateTime.now().subtract(const Duration(minutes: 20))));
      await t.pump(const Duration(milliseconds: 100));
      final linha =
          find.text('Open-Meteo/CAMS e INPE, qualidade do ar (modelo)');
      await t.scrollUntilVisible(linha, 200,
          scrollable: find.byType(Scrollable).first);
      expect(linha, findsOneWidget);
    });
  });
}

/// Linha como a RPC ar_contexto devolve (valores inventados).
Map<String, dynamic> _contexto({
  bool ok = true,
  bool semSensor = false,
  bool sensorPior = true,
  bool modeloPior = false,
  bool cautela = false,
  bool avisoLigado = false,
  int focos = 120,
}) =>
    {
      'region_id': 'r-compensa',
      'tem_sensor': !semSensor,
      'sensor_nome': semSensor ? null : 'Manaus',
      'sensor_provedor': semSensor ? null : 'AirGradient',
      'sensor_distancia_km': semSensor ? null : 2,
      'sensor_situacao': semSensor ? null : 'saudável',
      'comparacao_ok': ok && !semSensor,
      'sensor_pm25_24h': ok && !semSensor ? 80 : null,
      'sensor_nivel': ok && !semSensor ? 'N4' : null,
      'modelo_pm25_24h': ok && !semSensor ? 20 : null,
      'modelo_nivel': ok && !semSensor ? 'N2' : null,
      'sensor_pior': ok && !semSensor && sensorPior,
      'modelo_pior': ok && !semSensor && modeloPior,
      'epoca_fumaca': true,
      'focos_300km_72h': focos,
      'cautela_boa': cautela,
      'aviso_sensor_ligado': avisoLigado,
    };
