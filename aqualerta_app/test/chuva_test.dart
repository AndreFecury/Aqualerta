import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/features/alerts/presentation/screens/detalhe_alerta_screen.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/features/settings/presentation/screens/perfil_screen.dart';

import 'apoio/dados_exemplo.dart';
import 'telas_v3_test.dart' show montar;

/// Banco de exemplo com um aviso de chuva extrema ativo na Compensa (a
/// região seguida) e a coleta do CEMADEN rodando.
class CartaComChuva extends CartaFalsa {
  CartaComChuva({this.coletaHa = const Duration(minutes: 5)});
  final Duration? coletaHa;

  @override
  Future<List<AlertaV3>> alertas() async => [
        ...await super.alertas(),
        AlertaV3(
          id: 'chuva1',
          regiaoId: CartaFalsa.compensa.id,
          regiaoNome: 'Compensa, AM',
          titulo: 'Chuva extrema em Compensa: risco de grandes alagamentos',
          texto: 'O pluviômetro Compensa (CEMADEN) registrou 64 mm na última '
              'hora. Aviso automático do AquaAlerta; não substitui a Defesa Civil.',
          severidadeOriginal: Severidade.critico,
          ativo: true,
          emitidoEm: DateTime.now().subtract(const Duration(minutes: 7)),
          origem: AlertaV3.origemChuva,
        ),
      ];

  @override
  Future<DateTime?> chuvaUltimaColeta() async =>
      coletaHa == null ? null : DateTime.now().subtract(coletaHa!);
}

void main() {
  setUp(() => FundoMapa.desligado = true);

  group('modelo', () {
    final rioNormal = Estacao(
      id: 'e',
      codigoAna: '14990000',
      nome: 'Manaus',
      rio: 'Rio Negro',
      posicao: CartaFalsa.compensa.centro!,
      nivel: 16,
      lidoEm: DateTime.now(),
      cotas: const CotasEstacao(alerta: 27, inundacao: 27.5, severa: 29),
    );

    test('aviso de chuva não herda a severidade do rio', () {
      final chuva = AlertaV3(
        id: 'c',
        regiaoId: 'r',
        regiaoNome: 'R',
        titulo: 't',
        texto: 'x',
        severidadeOriginal: Severidade.alto,
        ativo: true,
        emitidoEm: DateTime(2026, 11, 19),
        origem: AlertaV3.origemChuva,
      );
      final ligado = chuva.comEstacao(rioNormal);
      expect(ligado.estacao, isNull);
      expect(ligado.severidade, Severidade.alto);
      expect(ligado.ehChuva, isTrue);
    });

    test('alerta do rio continua seguindo as cotas da estação', () {
      final rio = AlertaV3(
        id: 'r',
        regiaoId: 'r',
        regiaoNome: 'R',
        titulo: 't',
        texto: 'x',
        severidadeOriginal: Severidade.alto,
        ativo: true,
        emitidoEm: DateTime(2026, 11, 19),
        origem: 'telemetria-ana',
      ).comEstacao(rioNormal);
      expect(rio.estacao, isNotNull);
      expect(rio.severidade, Severidade.baixo);
      expect(rio.origem, 'telemetria-ana');
    });

    test('estado da coleta de chuva no Perfil', () {
      final agora = DateTime(2026, 11, 19, 12);
      expect(estadoChuva(null, agora: agora), 'Aguardando');
      expect(estadoChuva(agora.subtract(const Duration(minutes: 12)), agora: agora),
          'Ativa');
      expect(estadoChuva(agora.subtract(const Duration(minutes: 45)), agora: agora),
          'Atrasada');
    });
  });

  group('telas', () {
    testWidgets('cartão do mapa mostra o aviso de chuva primeiro', (t) async {
      await montar(t, const MapaScreen(), dados: CartaComChuva());
      expect(find.textContaining('chuva extrema nos pluviômetros'), findsOneWidget);
      // Selo do cartão no nível do aviso de chuva (crítico), não no do rio.
      expect(find.text(Severidade.critico.acao), findsWidgets);
    });

    testWidgets('detalhe do aviso de chuva', (t) async {
      await montar(t, const DetalheAlertaScreen(alertaId: 'chuva1'),
          dados: CartaComChuva());
      expect(find.text('Aviso de chuva'), findsOneWidget);
      expect(find.textContaining('não substitui a Defesa Civil'), findsOneWidget);
    });

    testWidgets('Perfil mostra o CEMADEN ativo com coleta recente', (t) async {
      await montar(t, const PerfilScreen(), dados: CartaComChuva());
      final linha = find.text('CEMADEN, chuva nos pluviômetros a cada 10 min');
      await t.scrollUntilVisible(linha, 200);
      expect(linha, findsOneWidget);
      expect(
          find.descendant(
              of: find.ancestor(of: linha, matching: find.byType(Row)).first,
              matching: find.text('Ativa')),
          findsOneWidget);
    });

    testWidgets('Perfil mostra "Atrasada" quando a coleta parou', (t) async {
      await montar(t, const PerfilScreen(),
          dados: CartaComChuva(coletaHa: const Duration(hours: 2)));
      await t.scrollUntilVisible(find.text('Atrasada'), 200);
      expect(find.text('Atrasada'), findsOneWidget);
    });
  });
}
