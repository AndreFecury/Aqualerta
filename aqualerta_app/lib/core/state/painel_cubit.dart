import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:equatable/equatable.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart'
    show InicioMapa;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/data/cache_regioes.dart';
import 'package:aqualerta/core/data/carta_datasource.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';

/// Estado compartilhado pelas telas Mapa, Alertas e Rios.
class Painel extends Equatable {
  const Painel({
    this.carregando = true,
    this.erro,
    this.regioes = const [],
    this.eventos = const [],
    this.estacoes = const [],
    this.alertas = const [],
    this.seguidas = const {},
    this.atualizadoEm,
    this.bancoSemViewsV3 = false,
    this.chuvaColetadaEm,
    this.avisosAr = const [],
  });

  /// Avisos de qualidade do ar pelo sensor (separados dos alertas de cheia).
  final List<AvisoAr> avisosAr;

  List<AvisoAr> get avisosArAtivos => [
        for (final a in avisosAr)
          if (a.ativo) a
      ];

  AvisoAr? avisoAr(String id) {
    for (final a in avisosAr) {
      if (a.id == id) return a;
    }
    return null;
  }

  final bool carregando;

  /// Mensagem para o usuário quando a última atualização falhou.
  final String? erro;
  final List<Regiao> regioes;
  final List<Evento> eventos;
  final List<Estacao> estacoes;
  final List<AlertaV3> alertas;
  final Set<String> seguidas;
  final DateTime? atualizadoEm;
  final bool bancoSemViewsV3;

  /// Última coleta dos pluviômetros do CEMADEN; `null` = ainda não há.
  final DateTime? chuvaColetadaEm;

  bool get temDados => atualizadoEm != null;

  List<AlertaV3> get ativos => [
        for (final a in alertas)
          if (a.ativo) a
      ];
  List<AlertaV3> get encerrados => [
        for (final a in alertas)
          if (!a.ativo) a
      ];

  Regiao? regiao(String id) {
    for (final r in regioes) {
      if (r.id == id) return r;
    }
    return null;
  }

  AlertaV3? alerta(String id) {
    for (final a in alertas) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Maior severidade entre os alertas ativos da região (Baixo se não houver).
  /// Aviso de qualidade do ar não conta: o risco aqui é de cheia.
  Severidade severidadeDaRegiao(String id) {
    var s = Severidade.baixo;
    for (final a in ativos) {
      if (a.ehAr) continue;
      if (a.regiaoId == id && a.severidade >= s) s = a.severidade;
    }
    return s;
  }

  /// A região mostrada no topo do mapa: a primeira que o usuário segue; se ele
  /// não segue nenhuma, a de maior risco agora. Empate (por exemplo, todos
  /// os rios baixos) fica com Manaus, onde o app abre.
  /// Seguida primeiro; senão, a de maior risco.
  Regiao? get regiaoPrincipal {
    for (final r in regioes) {
      if (seguidas.contains(r.id)) return r;
    }
    return regiaoDeMaiorRisco;
  }

  /// Região que o mapa mostra ao abrir, conforme a escolha no Perfil.
  /// Padrão: Manaus. Sem a região escolhida, cai na próxima opção.
  Regiao? regiaoInicial(InicioMapa modo) {
    Regiao? manaus;
    for (final r in regioes) {
      if (_ehManaus(r)) {
        manaus = r;
        break;
      }
    }
    switch (modo) {
      case InicioMapa.manaus:
        return manaus ?? regiaoDeMaiorRisco;
      case InicioMapa.seguida:
        for (final r in regioes) {
          if (seguidas.contains(r.id)) return r;
        }
        return manaus ?? regiaoDeMaiorRisco;
      case InicioMapa.maiorRisco:
        return regiaoDeMaiorRisco;
    }
  }

  /// A de maior risco agora (empate: Manaus primeiro).
  Regiao? get regiaoDeMaiorRisco {
    Regiao? pior;
    for (final r in regioes) {
      if (pior == null) {
        pior = r;
        continue;
      }
      final a = severidadeDaRegiao(r.id).index;
      final b = severidadeDaRegiao(pior.id).index;
      if (a > b || (a == b && _ehManaus(r) && !_ehManaus(pior))) pior = r;
    }
    return pior;
  }

  static bool _ehManaus(Regiao r) =>
      r.nome.trim().toLowerCase() == 'manaus' ||
      (r.municipio?.trim().toLowerCase() == 'manaus');

  bool get principalEhSeguida =>
      regiaoPrincipal != null && seguidas.contains(regiaoPrincipal!.id);

  Estacao? estacaoDaRegiao(Regiao? r) =>
      estacaoMaisProxima(r?.centro, estacoes);

  Painel copyWith({
    bool? carregando,
    String? erro,
    bool limparErro = false,
    List<Regiao>? regioes,
    List<Evento>? eventos,
    List<Estacao>? estacoes,
    List<AlertaV3>? alertas,
    Set<String>? seguidas,
    DateTime? atualizadoEm,
    bool? bancoSemViewsV3,
    List<AvisoAr>? avisosAr,
  }) =>
      Painel(
        carregando: carregando ?? this.carregando,
        erro: limparErro ? null : (erro ?? this.erro),
        regioes: regioes ?? this.regioes,
        eventos: eventos ?? this.eventos,
        estacoes: estacoes ?? this.estacoes,
        alertas: alertas ?? this.alertas,
        seguidas: seguidas ?? this.seguidas,
        atualizadoEm: atualizadoEm ?? this.atualizadoEm,
        bancoSemViewsV3: bancoSemViewsV3 ?? this.bancoSemViewsV3,
        chuvaColetadaEm: chuvaColetadaEm,
        avisosAr: avisosAr ?? this.avisosAr,
      );

  @override
  List<Object?> get props => [
        carregando,
        erro,
        regioes,
        eventos,
        estacoes,
        alertas,
        seguidas,
        atualizadoEm,
        bancoSemViewsV3,
        chuvaColetadaEm,
        avisosAr
      ];
}

class PainelCubit extends Cubit<Painel> {
  PainelCubit(this._dados,
      {bool ouvirTempoReal = true, CacheRegioes? cache, Random? sorteio})
      : _cache = cache ?? CacheRegioes(),
        _sorteio = sorteio ?? Random(),
        super(const Painel()) {
    carregar();
    if (ouvirTempoReal) {
      _ouvir();
      // Em segundo plano o app solta a conexão de tempo real depois de
      // [folgaSegundoPlano] (o Supabase gratuito tem 200 conexões; os avisos
      // importantes chegam por push). Ao voltar, reconecta e atualiza.
      _ciclo = AppLifecycleListener(
        onHide: () {
          _emSegundoPlano = true;
          _soltar?.cancel();
          _soltar = Timer(folgaSegundoPlano, _desligar);
        },
        onShow: () {
          _emSegundoPlano = false;
          _soltar?.cancel();
          if (_canal == null) {
            _ouvir();
            carregar(tudo: false);
          }
        },
      );
    }
  }

  /// Quanto o app espera em segundo plano antes de soltar a conexão (troca
  /// rápida de app não derruba nada).
  static const folgaSegundoPlano = Duration(seconds: 30);

  /// Espalha as recargas depois de um sinal: cada aparelho espera um tempo
  /// sorteado até este limite, para o servidor não receber todos de uma vez.
  static const espalhamento = Duration(seconds: 20);

  final CartaDatasource _dados;
  final CacheRegioes _cache;
  final Random _sorteio;
  RealtimeChannel? _canal;
  AppLifecycleListener? _ciclo;
  Timer? _espera;
  Timer? _soltar;
  bool _emSegundoPlano = false;

  void _ouvir() {
    _canal = _dados.ouvirMudancas(() {
      if (_espera?.isActive ?? false) return; // já tem recarga marcada
      final ms = _sorteio.nextInt(espalhamento.inMilliseconds + 1);
      _espera =
          Timer(Duration(milliseconds: 2000 + ms), () => carregar(tudo: false));
    }, aoFalhar: _reconectar, aoConectar: () => _tentativas = 0);
  }

  /// Esperas entre novas tentativas quando a inscrição no canal falha.
  static const esperasReconexao = [
    Duration(seconds: 2),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];
  int _tentativas = 0;
  Timer? _retentar;

  /// Inscrição recusada (ex.: token vencido ao abrir o app): solta o canal,
  /// renova a sessão e tenta de novo, com espera crescente.
  void _reconectar() {
    if (_retentar?.isActive ?? false) return;
    final c = _canal;
    _canal = null;
    if (c != null) {
      _dados.pararDeOuvir(c).catchError((_) {});
    }
    final espera =
        esperasReconexao[min(_tentativas, esperasReconexao.length - 1)];
    _tentativas++;
    _retentar = Timer(espera, () async {
      try {
        await _dados.renovarSessaoSeVencida();
      } catch (_) {}
      if (!isClosed && _canal == null && !_emSegundoPlano) {
        _ouvir();
        carregar(tudo: false);
      }
    });
  }

  Future<void> _desligar() async {
    _retentar?.cancel();
    final c = _canal;
    _canal = null;
    _espera?.cancel();
    if (c != null) {
      try {
        await _dados.pararDeOuvir(c);
      } catch (_) {}
    }
  }

  /// [tudo] = false recarrega só o que muda (alertas, leituras, eventos):
  /// regiões e regiões seguidas ficam como estão.
  Future<void> carregar({bool tudo = true}) async {
    if (!tudo && !state.temDados) tudo = true;
    emit(state.copyWith(carregando: true, limparErro: true));
    try {
      final resultados = await Future.wait([
        tudo ? _cache.obter(_dados.regioes) : Future.value(state.regioes),
        _dados.eventos(),
        _dados.estacoes(),
        _dados.alertas(),
        tudo ? _dados.regioesSeguidas() : Future.value(state.seguidas),
        _dados.chuvaUltimaColeta(),
        _dados.avisosAr(),
      ]);
      final regioes = resultados[0] as List<Regiao>;
      final estacoes = resultados[2] as List<Estacao>;
      final porId = {for (final r in regioes) r.id: r};
      final alertas = [
        for (final a in resultados[3] as List<AlertaV3>)
          a.comEstacao(estacaoMaisProxima(porId[a.regiaoId]?.centro, estacoes)),
      ];
      emit(Painel(
        carregando: false,
        regioes: regioes,
        eventos: resultados[1] as List<Evento>,
        estacoes: estacoes,
        alertas: alertas,
        seguidas: resultados[4] as Set<String>,
        atualizadoEm: DateTime.now(),
        bancoSemViewsV3: !_dados.viewsV3Disponiveis,
        chuvaColetadaEm: resultados[5] as DateTime?,
        avisosAr: resultados[6] as List<AvisoAr>,
      ));
    } catch (_) {
      emit(state.copyWith(
        carregando: false,
        erro: state.temDados
            ? 'Não foi possível atualizar. Mostrando os dados de ${_hora(state.atualizadoEm!)}.'
            : 'Não foi possível carregar os dados. Confira a internet e tente de novo.',
      ));
    }
  }

  Future<void> seguir(String regiaoId, {required bool seguir}) async {
    final novas = {...state.seguidas};
    seguir ? novas.add(regiaoId) : novas.remove(regiaoId);
    emit(state.copyWith(seguidas: novas));
    try {
      await _dados.seguir(regiaoId, seguir: seguir);
    } catch (_) {
      await carregar();
    }
  }

  String _hora(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Future<void> close() async {
    _espera?.cancel();
    _soltar?.cancel();
    _ciclo?.dispose();
    await _desligar();
    return super.close();
  }
}
