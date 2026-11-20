import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/atualizacao/atualizacao.dart';
import 'package:aqualerta/core/atualizacao/aviso_atualizacao.dart';
import 'package:aqualerta/shared/theme/aqua_theme.dart';

const _sha = '884b272df83a30b9d34fd59c0cb1e51c6bbb0d68be18ce63c84798fab3c31d72';

Map<String, Object?> _manifesto(
        {int codigo = 47, String? apk, String sha = _sha}) =>
    {
      'codigo': codigo,
      'versao': '4.7.0',
      'apk': apk ?? 'https://andrefecury.github.io/Aqualerta/app/aqualerta.apk',
      'sha256': sha,
      'tamanho': 56400000,
      'notas': 'Correções no mapa',
    };

AtualizacaoCubit _cubit(
        {Object? manifesto, int atual = 46, Instalar? instalar}) =>
    AtualizacaoCubit(
      buscar: () async => manifesto ?? _manifesto(),
      codigoAtual: () async => atual,
      instalar: instalar ?? (_) => const Stream.empty(),
    );

void main() {
  group('manifesto', () {
    test('lê um manifesto válido', () {
      final v = VersaoPublicada.doJson(_manifesto())!;
      expect(v.codigo, 47);
      expect(v.versao, '4.7.0');
      expect(v.tamanhoTexto, '56 MB');
      expect(v.notas, 'Correções no mapa');
    });

    test('recusa APK fora do GitHub do projeto, sem HTTPS ou sem SHA-256', () {
      expect(
          VersaoPublicada.doJson(_manifesto(apk: 'https://exemplo.com/a.apk')),
          isNull);
      expect(
          VersaoPublicada.doJson(
              _manifesto(apk: 'http://andrefecury.github.io/Aqualerta/a.apk')),
          isNull);
      expect(VersaoPublicada.doJson(_manifesto(sha: 'abc')), isNull);
      expect(VersaoPublicada.doJson(_manifesto(codigo: 0)), isNull);
      expect(VersaoPublicada.doJson('lixo'), isNull);
      expect(VersaoPublicada.doJson(null), isNull);
    });
  });

  group('verificação', () {
    test('versão maior publicada: oferece atualizar', () async {
      final c = _cubit();
      expect(await c.verificar(), isTrue);
      expect(c.state.fase, FaseAtualizacao.disponivel);
      expect(c.state.mostrarAviso, isTrue);
    });

    test('mesma versão ou menor: fica quieto', () async {
      final c = _cubit(atual: 47);
      expect(await c.verificar(), isFalse);
      expect(c.state.mostrarAviso, isFalse);
    });

    test('sem internet: fica quieto, sem erro', () async {
      final c = AtualizacaoCubit(
          buscar: () async => throw Exception('sem rede'),
          codigoAtual: () async => 46,
          instalar: (_) => const Stream.empty());
      expect(await c.verificar(), isFalse);
      expect(c.state.fase, FaseAtualizacao.nada);
    });

    test('"Agora não" esconde; procurar pelo Perfil mostra de novo', () async {
      final c = _cubit();
      await c.verificar();
      c.dispensar();
      expect(c.state.mostrarAviso, isFalse);
      await c.verificar(); // nova abertura automática: continua escondido
      expect(c.state.mostrarAviso, isFalse);
      await c.verificar(manual: true);
      expect(c.state.mostrarAviso, isTrue);
    });
  });

  group('download', () {
    test('progresso e depois o instalador do Android', () async {
      final passos = StreamController<PassoInstalacao>();
      final c = _cubit(instalar: (_) => passos.stream);
      await c.verificar();
      c.atualizar();
      expect(c.state.fase, FaseAtualizacao.baixando);
      passos
          .add(const PassoInstalacao(FaseAtualizacao.baixando, progresso: 40));
      await Future<void>.delayed(Duration.zero);
      expect(c.state.progresso, 40);
      passos.add(const PassoInstalacao(FaseAtualizacao.instalando));
      await Future<void>.delayed(Duration.zero);
      expect(c.state.fase, FaseAtualizacao.instalando);
      await passos.close();
    });

    test('arquivo que não confere vira erro com explicação', () async {
      final c = _cubit(
          instalar: (_) => Stream.value(const PassoInstalacao(
              FaseAtualizacao.erro,
              erro: 'O arquivo baixado não confere.')));
      await c.verificar();
      c.atualizar();
      await Future<void>.delayed(Duration.zero);
      expect(c.state.fase, FaseAtualizacao.erro);
      expect(c.state.erro, contains('não confere'));
    });
  });

  group('faixa na tela', () {
    Future<AtualizacaoCubit> montar(WidgetTester t,
        {Instalar? instalar}) async {
      final c = _cubit(instalar: instalar);
      await c.verificar();
      await t.pumpWidget(MaterialApp(
        theme: AquaTheme.claro,
        home: Scaffold(
          bottomNavigationBar:
              BlocProvider.value(value: c, child: const AvisoAtualizacao()),
        ),
      ));
      await t.pumpAndSettle();
      return c;
    }

    testWidgets('mostra a versão nova e o tamanho', (t) async {
      await montar(t);
      expect(find.text('Nova versão 4.7.0 do AquaAlerta'), findsOneWidget);
      expect(find.textContaining('56 MB'), findsOneWidget);
    });

    testWidgets('Atualizar começa o download e mostra o progresso', (t) async {
      final passos = StreamController<PassoInstalacao>();
      await montar(t, instalar: (_) => passos.stream);
      await t.tap(find.byKey(const Key('atualizar-app')));
      passos
          .add(const PassoInstalacao(FaseAtualizacao.baixando, progresso: 25));
      await t.pump();
      await t.pump();
      expect(find.textContaining('25%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await passos.close();
    });

    testWidgets('Agora não esconde a faixa', (t) async {
      await montar(t);
      await t.tap(find.text('Agora não'));
      await t.pumpAndSettle();
      expect(find.text('Nova versão 4.7.0 do AquaAlerta'), findsNothing);
    });
  });
}
