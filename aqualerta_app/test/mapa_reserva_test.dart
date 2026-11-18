import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/features/alerts/presentation/screens/detalhe_alerta_screen.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/shared/widgets/logo_maptiler.dart';
import 'telas_v3_test.dart' show montar;

/// O mini-mapa fica mais abaixo numa lista preguiçosa: rola até ele.
Future<void> _rolarAteOMapa(WidgetTester t) async {
  await t.scrollUntilVisible(find.byType(FlutterMap), 250,
      scrollable: find
          .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down)
          .first);
  await t.pump();
}

void main() {
  tearDown(() {
    FundoMapa.chaveDeTeste = null;
    FundoMapa.voltarAoMapTiler();
    FundoMapa.tempoNaReserva = const Duration(minutes: 15);
    FundoMapa.desligado = true;
  });

  group('FundoMapa', () {
    test('sem chave usa CARTO e não pede o logo do MapTiler', () {
      final f = FundoMapa.para(TipoMapa.carta, Brightness.light);
      expect(f.url, contains('cartocdn.com'));
      expect(f.ehMapTiler, isFalse);
    });

    test('com chave usa MapTiler em todos os tipos', () {
      FundoMapa.chaveDeTeste = 'chave-teste';
      for (final tipo in TipoMapa.values) {
        final f = FundoMapa.para(tipo, Brightness.dark);
        expect(f.ehMapTiler, isTrue, reason: '$tipo');
        expect(f.url, contains('key=chave-teste'));
      }
    });

    test('na reserva volta aos mapas gratuitos e depois tenta o MapTiler', () {
      FundoMapa.chaveDeTeste = 'chave-teste';
      FundoMapa.trocarParaReserva();
      expect(FundoMapa.usandoReserva, isTrue);
      expect(FundoMapa.para(TipoMapa.carta, Brightness.light).url,
          contains('cartocdn.com'));
      expect(FundoMapa.para(TipoMapa.satelite, Brightness.light).url,
          contains('maps.eox.at'));

      FundoMapa.tempoNaReserva = Duration.zero; // a reserva "venceu"
      expect(FundoMapa.usandoReserva, isFalse);
      expect(FundoMapa.para(TipoMapa.carta, Brightness.light).ehMapTiler,
          isTrue);
    });
  });

  test('4 falhas do MapTiler em 10 s trocam para a reserva, 3 não', () {
    FundoMapa.chaveDeTeste = 'chave-teste';
    for (var i = 0; i < 3; i++) {
      expect(FundoMapa.registrarFalhaDoMapTiler(), isFalse);
    }
    expect(FundoMapa.usandoReserva, isFalse);
    expect(FundoMapa.registrarFalhaDoMapTiler(), isTrue);
    expect(FundoMapa.usandoReserva, isTrue);
    // Já na reserva, novas falhas (tiles antigos chegando) não contam.
    expect(FundoMapa.registrarFalhaDoMapTiler(), isFalse);
  });

  test('sem chave, falha nunca troca nada', () {
    for (var i = 0; i < 10; i++) {
      expect(FundoMapa.registrarFalhaDoMapTiler(), isFalse);
    }
    expect(FundoMapa.usandoReserva, isFalse);
  });

  // Nos testes toda requisição de rede responde 400, então os tiles do
  // MapTiler falham de verdade: é a mesma situação da Wi-Fi que bloqueia
  // api.maptiler.com.
  testWidgets('MapTiler falhando troca para o mapa gratuito',
      (t) async {
    FundoMapa.chaveDeTeste = 'chave-teste';
    FundoMapa.desligado = false;
    await montar(t, const MapaScreen());

    for (var i = 0; i < 20 && !FundoMapa.usandoReserva; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(FundoMapa.usandoReserva, isTrue);
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(LogoMapTiler), findsNothing);
    // Aqui o mapa gratuito também falha (toda rede responde 400), então
    // aparece só o aviso de mapa sem carregar, sem empilhar o da troca.
    expect(find.textContaining('não está carregando'), findsOneWidget);
    expect(find.textContaining('Mostrando o mapa alternativo'), findsNothing);

    // Desmonta e deixa os timers do aviso vencerem.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 10));
    expect(t.takeException(), isNull);
  });

  testWidgets('mapa do alerta com MapTiler mostra o logo dele', (t) async {
    FundoMapa.chaveDeTeste = 'chave-teste';
    // Sem rede no teste o MapTiler falharia e o app trocaria de mapa;
    // com reserva de duração zero ele continua no MapTiler.
    FundoMapa.tempoNaReserva = Duration.zero;
    FundoMapa.desligado = false;
    await montar(t, const DetalheAlertaScreen(alertaId: 'a1'));
    await _rolarAteOMapa(t);
    expect(find.byType(LogoMapTiler, skipOffstage: false), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    // Os tiles falham (sem rede no teste) e o Flutter registra o erro de
    // imagem; no app isso só vai para o log.
    t.takeException();
  });

  testWidgets('sem MapTiler o logo não aparece', (t) async {
    FundoMapa.desligado = false;
    await montar(t, const DetalheAlertaScreen(alertaId: 'a1'));
    await _rolarAteOMapa(t);
    expect(find.byType(FlutterMap, skipOffstage: false), findsOneWidget);
    expect(find.byType(LogoMapTiler, skipOffstage: false), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    // Os tiles falham (sem rede no teste) e o Flutter registra o erro de
    // imagem; no app isso só vai para o log.
    t.takeException();
  });
}
