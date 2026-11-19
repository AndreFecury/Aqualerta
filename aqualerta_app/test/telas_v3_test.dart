import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/features/alerts/presentation/screens/alertas_screen.dart';
import 'package:aqualerta/features/alerts/presentation/screens/detalhe_alerta_screen.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/features/regions/presentation/screens/rios_screen.dart';
import 'package:aqualerta/features/settings/presentation/cubit/aparencia_cubit.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';
import 'package:aqualerta/features/settings/presentation/screens/perfil_screen.dart';
import 'package:aqualerta/shared/theme/aqua_theme.dart';
import 'package:aqualerta/core/domain/satelite.dart';
import 'package:aqualerta/features/map/data/satelite_repository.dart';
import 'apoio/dados_exemplo.dart';

/// Monta [tela] num celular de 390 × 844 com os dados de exemplo.
Future<void> montar(WidgetTester t, Widget tela,
    {ThemeData? tema,
    double escala = 1,
    FonteSatelite? satelite,
    Map<String, Object>? preferencias}) async {
  SharedPreferences.setMockInitialValues(preferencias ?? {});
  final prefs = await SharedPreferences.getInstance();
  final painel = PainelCubit(CartaFalsa(), ouvirTempoReal: false);
  await t.binding.setSurfaceSize(const Size(390, 844));
  await t.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider.value(value: painel),
        BlocProvider(create: (_) => AparenciaCubit(prefs)),
        BlocProvider(create: (_) => NotificacoesCubit(prefs)),
        BlocProvider(create: (_) => CamadasCubit(prefs)),
        BlocProvider(
            create: (_) => SateliteCubit(satelite ?? SateliteVazio())),
      ],
      child: MaterialApp(
        theme: tema ?? AquaTheme.claro,
        home: MediaQuery(
          data: MediaQueryData(
              size: const Size(390, 844),
              textScaler: TextScaler.linear(escala)),
          child: tela,
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
}

/// Banco sem nenhuma observação de satélite.
class SateliteVazio implements FonteSatelite {
  int chamadas = 0;
  @override
  Future<ObservacaoSatelite?> ultima(String regionId) async {
    chamadas++;
    return null;
  }
}

void main() {
  FundoMapa.desligado = true;
  final telas = <String, Widget>{
    'mapa': const MapaScreen(),
    'alertas': const AlertasScreen(),
    'detalhe': const DetalheAlertaScreen(alertaId: 'a1'),
    'rios': const RiosScreen(),
    'perfil': const PerfilScreen(),
  };

  for (final escala in [1.0, 1.6]) {
    for (final tema in [
      ('claro', AquaTheme.claro),
      ('escuro', AquaTheme.escuro)
    ]) {
      for (final MapEntry(key: nome, value: tela) in telas.entries) {
        testWidgets('$nome cabe na tela (${tema.$1}, letra ${escala}x)',
            (t) async {
          await montar(t, tela, tema: tema.$2, escala: escala);
          expect(t.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('severidade no app segue a régua: Porto Velho aparece como Alto',
      (t) async {
    await montar(t, const AlertasScreen());
    expect(find.text('Rio Madeira com elevação significativa'), findsOneWidget);
    expect(find.text('Prepare-se'), findsNWidgets(2));
  });

  testWidgets('estação sem leitura recente avisa em vez de mostrar número',
      (t) async {
    await montar(t, const RiosScreen());
    expect(find.text('Sem leitura recente'), findsOneWidget);
  });

  testWidgets('tocar numa região voa até ela e abre o cartão sem erro',
      (t) async {
    await montar(t, const MapaScreen());
    final marcas = find.bySemanticsLabel(RegExp('risco'));
    expect(marcas, findsWidgets);
    await t.tap(marcas.first, warnIfMissed: false);
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(t.takeException(), isNull);
  });
}
