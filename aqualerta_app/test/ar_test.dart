import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha())]));
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(find.text('Ar moderada · índice 54'), 200,
          scrollable: _rolavel());
      expect(find.textContaining('partículas finas (MP2,5)'), findsOneWidget);
      expect(find.textContaining('pior previsto em 48 h: moderada (55)'),
          findsOneWidget);
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

    testWidgets('fumaça provável aparece com o número de focos', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha(fumaca: true, focos: 12))]));
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(
          find.textContaining('a fumaça pode ser a causa'), 200,
          scrollable: _rolavel());
      expect(find.textContaining('12 focos de queimada'), findsOneWidget);
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
      final fonte = ArFixo([ResumoAr.doJson(_linha())])..falhar = true;
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

    testWidgets('desligada por padrão: nada pintado e sem legenda', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha())]));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('camada-ar')), findsNothing);
      expect(find.textContaining('Ar (modelo)'), findsNothing);
    });

    testWidgets('ligada: pinta a região com a cor do IQAr e mostra a legenda',
        (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha())]),
          preferencias: {
            'mapa.camadas': ['regioes', 'qualidadeAr'],
          });
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      final camada =
          t.widget<PolygonLayer>(find.byKey(const ValueKey('camada-ar')));
      // Só a região com estimativa (r-compensa) é pintada.
      expect(camada.polygons, isNotEmpty);
      final cor = NivelAr.n2.cor(Brightness.light);
      for (final p in camada.polygons) {
        expect(p.borderColor, cor);
        expect(p.color, cor.withValues(alpha: 0.32));
        expect(p.borderStrokeWidth, 0,
            reason: 'com as regiões ligadas, o contorno é o risco de cheia');
      }
      expect(find.textContaining('Ar (modelo) · '), findsOneWidget);
      for (final n in NivelAr.values) {
        expect(find.byKey(ValueKey('legenda-ar-${n.name}')), findsOneWidget);
      }
    });

    testWidgets('sem as regiões ligadas, a camada desenha o próprio contorno',
        (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha(iqar: 150))]),
          preferencias: {
            'mapa.camadas': ['qualidadeAr'],
          });
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      final camada =
          t.widget<PolygonLayer>(find.byKey(const ValueKey('camada-ar')));
      expect(camada.polygons, isNotEmpty);
      expect(camada.polygons.first.borderStrokeWidth, 1.8);
      expect(
          camada.polygons.first.borderColor, NivelAr.n4.cor(Brightness.light));
    });

    testWidgets('sem estimativa: nada pintado e a legenda diz isso', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([ResumoAr.doJson(_linha(iqar: null))]),
          preferencias: {
            'mapa.camadas': ['regioes', 'qualidadeAr'],
          });
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(
          t
              .widget<PolygonLayer>(find.byKey(const ValueKey('camada-ar')))
              .polygons,
          isEmpty);
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

  group('Perfil', () {
    test('preferência de ar vai para o banco', () {
      expect(const PreferenciasNotificacao().paraBanco()['ar'], true);
      expect(const PreferenciasNotificacao(ar: false).paraBanco()['ar'], false);
    });

    testWidgets('chave "Qualidade do ar" desliga e fica salva', (t) async {
      await montar(t, const PerfilScreen());
      final chave = find.byKey(const Key('avisos-ar'));
      await t.scrollUntilVisible(chave, 200,
          scrollable: find.byType(Scrollable).first);
      await t.tap(chave);
      await t.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('avisos.ar'), isFalse);
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
