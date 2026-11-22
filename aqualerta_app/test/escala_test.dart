import 'dart:math';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/data/cache_regioes.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';

import 'apoio/dados_exemplo.dart';

const _manaus = Regiao(
  id: 'r1',
  nome: 'Manaus',
  uf: 'AM',
  municipio: 'Manaus',
  areaKm2: 11401.1,
  centro: LatLng(-3.1190275, -60.0217314),
  contornos: [
    [LatLng(-3.0, -60.0), LatLng(-3.1, -60.1), LatLng(-3.2, -60.0)]
  ],
);

/// Conta o que foi pedido ao servidor e guarda o "ouvinte" do sinal.
class _CartaContada extends CartaFalsa {
  int regioesPedidas = 0;
  int seguidasPedidas = 0;
  int alertasPedidos = 0;
  int canaisFechados = 0;
  void Function()? sinal;

  @override
  Future<List<Regiao>> regioes() async {
    regioesPedidas++;
    return super.regioes();
  }

  @override
  Future<Set<String>> regioesSeguidas() async {
    seguidasPedidas++;
    return super.regioesSeguidas();
  }

  @override
  Future<List<AlertaV3>> alertas() async {
    alertasPedidos++;
    return super.alertas();
  }

  @override
  RealtimeChannel ouvirMudancas(void Function() aoMudar,
      {void Function()? aoFalhar, void Function()? aoConectar}) {
    sinal = aoMudar;
    falha = aoFalhar;
    canaisAbertos++;
    // Canal só criado, nunca conectado.
    return SupabaseClient('http://localhost', 'x',
            authOptions: const AuthClientOptions(autoRefreshToken: false))
        .channel('teste');
  }

  @override
  Future<void> pararDeOuvir(RealtimeChannel canal) async => canaisFechados++;

  void Function()? falha;
  int canaisAbertos = 0;
  int renovacoes = 0;

  @override
  Future<void> renovarSessaoSeVencida() async => renovacoes++;
}

void main() {
  group('Cache dos municípios', () {
    late DateTime agora;
    late SharedPreferences prefs;
    late int buscas;
    Future<List<Regiao>> buscar() async {
      buscas++;
      return const [_manaus];
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      agora = DateTime(2026, 11, 21, 12);
      buscas = 0;
    });
    CacheRegioes cache() => CacheRegioes(prefs: prefs, agora: () => agora);

    test('baixa na primeira vez e depois usa o guardado por 24 h', () async {
      expect((await cache().obter(buscar)).single.nome, 'Manaus');
      expect(buscas, 1);
      agora = agora.add(const Duration(hours: 23));
      final r = (await cache().obter(buscar)).single;
      expect(buscas, 1, reason: 'não foi ao servidor');
      expect(r.contornos.single.length, 3);
      expect(r.contornos.single[1].latitude, closeTo(-3.1, 1e-9));
      expect(r.centro!.longitude, closeTo(-60.02173, 1e-5));
      expect(r.areaKm2, 11401.1);
      agora = agora.add(const Duration(hours: 2));
      await cache().obter(buscar);
      expect(buscas, 2, reason: 'venceu: baixa de novo');
    });

    test('puxar para atualizar ignora a validade', () async {
      await cache().obter(buscar);
      await cache().obter(buscar, forcar: true);
      expect(buscas, 2);
    });

    test('sem internet usa o guardado mesmo vencido', () async {
      await cache().obter(buscar);
      agora = agora.add(const Duration(days: 10));
      final r = await cache().obter(() async => throw Exception('offline'));
      expect(r.single.id, 'r1');
    });

    test('sem internet e sem nada guardado: o erro sobe', () async {
      expect(cache().obter(() async => throw Exception('offline')),
          throwsException);
    });

    test('lista vazia do servidor não apaga o guardado', () async {
      await cache().obter(buscar);
      final r = await cache().obter(() async => const [], forcar: true);
      expect(r.single.id, 'r1');
    });

    test('guardado corrompido: baixa de novo', () async {
      await prefs.setString(CacheRegioes.chave, '{isso não é json');
      await cache().obter(buscar);
      expect(buscas, 1);
    });
  });

  group('Painel', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('sinal "mudou" recarrega só o que muda, espalhado no tempo',
        (t) async {
      final dados = _CartaContada();
      final painel = PainelCubit(dados, sorteio: Random(1));
      await t.pump(const Duration(milliseconds: 10));
      expect(painel.state.temDados, isTrue);
      expect(dados.regioesPedidas, 1);
      expect(dados.alertasPedidos, 1);

      // Três sinais seguidos viram uma recarga só.
      dados.sinal!();
      dados.sinal!();
      dados.sinal!();
      await t.pump(const Duration(milliseconds: 1900));
      expect(dados.alertasPedidos, 1, reason: 'espera pelo menos 2 s');
      await t.pump(PainelCubit.espalhamento);
      await t.pump(const Duration(milliseconds: 10));
      expect(dados.alertasPedidos, 2);
      expect(dados.regioesPedidas, 1,
          reason: 'regiões não são baixadas de novo');
      expect(dados.seguidasPedidas, 1);
      expect(painel.state.regioes, isNotEmpty);
      await painel.close();
    });

    testWidgets('em segundo plano solta a conexão; ao voltar, reconecta',
        (t) async {
      final dados = _CartaContada();
      final painel = PainelCubit(dados, sorteio: Random(1));
      await t.pump(const Duration(milliseconds: 10));
      final ouvinte1 = dados.sinal;

      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await t.pump(const Duration(seconds: 10));
      expect(dados.canaisFechados, 0,
          reason: 'troca rápida de app não derruba');
      await t.pump(PainelCubit.folgaSegundoPlano);
      expect(dados.canaisFechados, 1);

      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(milliseconds: 10));
      expect(dados.sinal, isNot(same(ouvinte1)), reason: 'ouvindo de novo');
      expect(dados.alertasPedidos, 2, reason: 'atualiza ao voltar');
      expect(dados.regioesPedidas, 1);
      await painel.close();
    });

    testWidgets('pausa curta não reconecta nem recarrega', (t) async {
      final dados = _CartaContada();
      final painel = PainelCubit(dados, sorteio: Random(1));
      await t.pump(const Duration(milliseconds: 10));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await t.pump(const Duration(seconds: 5));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(PainelCubit.folgaSegundoPlano);
      expect(dados.canaisFechados, 0);
      expect(dados.alertasPedidos, 1);
      await painel.close();
    });

    testWidgets('inscrição recusada (token vencido): renova e reconecta',
        (t) async {
      final dados = _CartaContada();
      final painel = PainelCubit(dados, sorteio: Random(1));
      await t.pump(const Duration(milliseconds: 10));
      expect(dados.canaisAbertos, 1);

      dados.falha!();
      expect(dados.canaisFechados, 1, reason: 'solta o canal recusado');
      await t.pump(const Duration(seconds: 1));
      expect(dados.canaisAbertos, 1, reason: 'espera antes de tentar');
      await t.pump(const Duration(seconds: 1, milliseconds: 10));
      expect(dados.renovacoes, 1, reason: 'renova a sessão antes');
      expect(dados.canaisAbertos, 2);
      expect(dados.alertasPedidos, 2, reason: 'atualiza o que perdeu');

      // Falhou de novo: a espera cresce (10 s).
      dados.falha!();
      await t.pump(const Duration(seconds: 9));
      expect(dados.canaisAbertos, 2);
      await t.pump(const Duration(seconds: 1, milliseconds: 10));
      expect(dados.canaisAbertos, 3);

      // Em segundo plano não insiste.
      dados.falha!();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await t.pump(const Duration(seconds: 31));
      expect(dados.canaisAbertos, 3);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(milliseconds: 10));
      expect(dados.canaisAbertos, 4, reason: 'ao voltar, conecta');
      await painel.close();
    });
  });
}
