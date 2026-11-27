import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/shared/widgets/selo_ar.dart';

import 'telas_v3_test.dart' show montar, ArFixo;

/// Replay de 25-26/11/2026: o que o cartão (e o selo do mapa) mostraria às 06:00
/// e às 19:42 locais de 26/11, em Manaus (sensor calado desde 10:00 UTC) e em
/// Porto Velho (sensor em dia), em três versões:
///   - 4.11.1 (antes do "agora"): manchete = modelo CAMS;
///   - 4.12.0 (a publicada antes desta fase): manchete = modelo, "Sem medição agora"
///     só com o sensor parado ou ausente, e o "agora" do sensor como linha extra;
///   - nova: manchete = sensor quando está em dia.
///
/// Os dados vêm de test/fixtures/ar_replay.json, gerado pelas RPCs do servidor
/// (supabase/tests/fixtures/ar_replay_snapshot.sql) sobre uma RECONSTRUÇÃO das
/// séries: ids, nomes e valores INVENTADOS a partir dos fatos informados pelo
/// dono, NÃO a série real. Ver docs/ar-replay-26-11.md.
///
/// As versões antigas são cópias CONGELADAS da lógica daquelas versões (bloco_ar.dart,
/// ResumoAr.semMedicaoAgora e textoSeloAr em 4.11.1 e no commit 5641a3c = 4.12.0);
/// só a versão nova roda o widget de verdade.

Map<String, dynamic> _fixo(Object? m) =>
    {...(m as Map<String, dynamic>), 'region_id': 'r-compensa'};

Map<String, dynamic> _cenario(String regiao, String rotulo) {
  final d = jsonDecode(File('test/fixtures/ar_replay.json').readAsStringSync())
      as Map<String, dynamic>;
  return (d['cenarios'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((c) => c['regiao'] == regiao && c['rotulo'] == rotulo);
}

/// Monta o ResumoAr como o ArRepository monta a partir das três RPCs.
ResumoAr _resumo(Map<String, dynamic> c) {
  final agora = _fixo(c['agora']);
  return ResumoAr.doJson(_fixo(c['resumo']))
      .comContexto(ContextoAr.doJson(_fixo(c['contexto'])))
      .comAgora(AgoraAr.doJson(agora))
      .comSemDados(SemDadosSensor.doJson(agora));
}

String _num(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

// ---- 4.11.1: manchete do modelo, com a cautela do "Boa" ---------------------
String cartao4111(ResumoAr r) {
  final n = r.nivel;
  if (n == null) return 'Sem estimativa';
  final cautela = n == NivelAr.n1 && (r.contexto?.cautelaBoa ?? false);
  return 'Ar ${n.nome.toLowerCase()} · índice ${r.iqar}'
      '${cautela ? ' (com cautela)' : ''}';
}

/// Selo do mapa nas duas versões antigas: sempre a categoria do modelo.
String selo4110e4120(ResumoAr r) {
  final n = r.nivel;
  if (n == null) return 'Ar sem estimativa';
  final cautela = n == NivelAr.n1 && (r.contexto?.cautelaBoa ?? false);
  return 'Ar ${r.iqar} · ${n.nome}${cautela ? ' (estimativa)' : ''}';
}

// ---- 4.12.0 (commit 5641a3c) ------------------------------------------------
bool semMedicao4120(ResumoAr r) {
  if (r.agora != null) return false;
  if (r.semDados != null) return true;
  final c = r.contexto;
  return c == null || !c.temSensor || c.sensorSituacao == 'parado';
}

String cartao4120(ResumoAr r) {
  final n = r.nivel!;
  if (semMedicao4120(r)) {
    return 'Sem medição agora (estimativa do modelo: '
        'ar ${n.nome.toLowerCase()}, índice ${r.iqar})';
  }
  final a = r.agora;
  final cautela = n == NivelAr.n1 && (r.contexto?.cautelaBoa ?? false);
  final piorou = a != null && a.piorou(n);
  return 'Ar ${n.nome.toLowerCase()} · índice ${r.iqar}'
      '${cautela ? ' (com cautela)' : ''}'
      '${a != null ? ' + linha "Agora (sensor): ${_num(a.pm25)} µg/m³, faixa ${a.nivel.nome.toLowerCase()}"' : ''}'
      '${piorou ? ' + aviso "o ar piorou"' : ''}';
}

// ---- nova: renderiza o widget de verdade -----------------------------------
Finder _rolavel() => find
    .descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable))
    .first;

Future<String> cartaoNovo(WidgetTester t, ResumoAr r) async {
  await montar(t, const MapaScreen(), ar: ArFixo([r]));
  await t.pump(const Duration(milliseconds: 100));
  await t.scrollUntilVisible(find.text('Limitações'), 200,
      scrollable: _rolavel());
  if (find.byKey(const Key('ar-sem-medicao')).evaluate().isNotEmpty) {
    final modelo = find.byKey(const Key('ar-estimativa-modelo'));
    final linha =
        modelo.evaluate().isEmpty ? '' : ' (estimativa do modelo, rotulada)';
    return 'Sem medição agora$linha';
  }
  final selo = find.descendant(
      of: find.byKey(const Key('ar-manchete-sensor')),
      matching: find.byType(SeloAr));
  final texto = t
      .widget<Text>(
          find.descendant(of: selo, matching: find.byType(Text)).first)
      .data!;
  return '$texto (sensor)';
}

void main() {
  final tem = File('test/fixtures/ar_replay.json').existsSync();

  group('Replay 26/11 (reconstrução, ids e valores inventados)', () {
    test('o JSON do replay é a reconstrução e diz isso', () {
      final d =
          jsonDecode(File('test/fixtures/ar_replay.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(d['aviso'], contains('RECONSTRUÇÃO'));
      expect((d['cenarios'] as List), hasLength(4));
      // Nada de id de sensor real nem dado pessoal no fixture.
      final bruto = File('test/fixtures/ar_replay.json').readAsStringSync();
      expect(bruto, isNot(contains(RegExp(r'\d{8,}'))),
          reason: 'sem números longos (id de sensor ou de estação)');
      expect(bruto, isNot(contains('@')));
    }, skip: !tem);

    group(
        'Manaus às 06:00 (sensor acabou de mandar 180,7 µg/m³; modelo "moderada")',
        () {
      late ResumoAr r;
      setUp(() => r = _resumo(_cenario('Manaus', '06:00 locais')));

      test('o que cada versão mostra', () {
        expect(cartao4111(r), 'Ar moderada · índice 64');
        expect(
            cartao4120(r),
            'Ar moderada · índice 64 + linha "Agora (sensor): 180,7 µg/m³, '
            'faixa péssima" + aviso "o ar piorou"');
        expect(selo4110e4120(r), 'Ar 64 · Moderada');
        expect(textoSeloAr(r), 'Ar Péssima · sensor');
      });

      testWidgets('cartão novo: manchete do sensor, "péssima"', (t) async {
        expect(await cartaoNovo(t, r), 'Ar péssima (sensor)');
        expect(
            find.textContaining(
                'O modelo está bem abaixo do que o sensor mede'),
            findsOneWidget);
        expect(find.text('Ar moderada · índice 64'), findsNothing);
      });
    }, skip: !tem);

    group('Manaus às 19:42 (13 h sem leitura; modelo "moderada", IQAr 80)', () {
      late ResumoAr r;
      setUp(() => r = _resumo(_cenario('Manaus', '19:42 locais')));

      test('o que cada versão mostra', () {
        expect(cartao4111(r), 'Ar moderada · índice 80');
        expect(cartao4120(r),
            'Sem medição agora (estimativa do modelo: ar moderada, índice 80)');
        expect(selo4110e4120(r), 'Ar 80 · Moderada');
        expect(textoSeloAr(r), 'Ar sem medição');
        expect(r.semDados?.horas, 13);
      });

      testWidgets('cartão novo: continua "Sem medição agora" (sem categoria)',
          (t) async {
        expect(await cartaoNovo(t, r),
            'Sem medição agora (estimativa do modelo, rotulada)');
        expect(find.byType(SeloAr), findsNothing);
        expect(find.textContaining('sem dados há 13 horas'), findsOneWidget);
        expect(find.byKey(const Key('ar-modelo-subestima')), findsOneWidget);
      });
    }, skip: !tem);

    for (final rotulo in ['06:00 locais', '19:42 locais']) {
      group(
          'Porto Velho às ${rotulo.substring(0, 5)} (sensor em dia, "moderada"; '
          'modelo "boa")', () {
        late ResumoAr r;
        setUp(() => r = _resumo(_cenario('Porto Velho', rotulo)));

        test('o que cada versão mostra', () {
          expect(cartao4111(r), 'Ar boa · índice 40 (com cautela)');
          expect(cartao4120(r),
              startsWith('Ar boa · índice 40 (com cautela) + linha'));
          expect(cartao4120(r), contains('faixa moderada'));
          expect(selo4110e4120(r), 'Ar 40 · Boa (estimativa)');
          expect(textoSeloAr(r), 'Ar Moderada · sensor');
        });

        testWidgets('cartão novo: manchete do sensor, "moderada"', (t) async {
          expect(await cartaoNovo(t, r), 'Ar moderada (sensor)');
          expect(find.text('Ar boa · índice 40'), findsNothing);
        });
      }, skip: !tem);
    }

    test(
        'em nenhum dos quatro cenários a versão nova mostra categoria do modelo '
        'como manchete', () {
      for (final (regiao, rotulo) in [
        ('Manaus', '06:00 locais'),
        ('Manaus', '19:42 locais'),
        ('Porto Velho', '06:00 locais'),
        ('Porto Velho', '19:42 locais'),
      ]) {
        final r = _resumo(_cenario(regiao, rotulo));
        final cat = r.categoriaVisivel;
        expect(
            cat == null ||
                cat.origem != OrigemAr.modelo ||
                cat.nivel.index >= 2,
            isTrue,
            reason: '$regiao $rotulo');
      }
    }, skip: !tem);
  });
}
