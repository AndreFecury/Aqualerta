import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/data/carta_datasource.dart';
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
  });

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
  Severidade severidadeDaRegiao(String id) {
    var s = Severidade.baixo;
    for (final a in ativos) {
      if (a.regiaoId == id && a.severidade >= s) s = a.severidade;
    }
    return s;
  }

  /// A região mostrada no topo do mapa: a primeira que o usuário segue; se ele
  /// não segue nenhuma, a de maior risco agora. Empate (por exemplo, todos
  /// os rios baixos) fica com Manaus, onde o app abre.
  Regiao? get regiaoPrincipal {
    for (final r in regioes) {
      if (seguidas.contains(r.id)) return r;
    }
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
        bancoSemViewsV3
      ];
}

class PainelCubit extends Cubit<Painel> {
  PainelCubit(this._dados, {bool ouvirTempoReal = true})
      : super(const Painel()) {
    carregar();
    if (ouvirTempoReal) {
      _canal = _dados.ouvirMudancas(() {
        _espera?.cancel();
        // Junta várias mudanças seguidas numa única atualização.
        _espera = Timer(const Duration(seconds: 2), carregar);
      });
    }
  }

  final CartaDatasource _dados;
  RealtimeChannel? _canal;
  Timer? _espera;

  Future<void> carregar() async {
    emit(state.copyWith(carregando: true, limparErro: true));
    try {
      final resultados = await Future.wait([
        _dados.regioes(),
        _dados.eventos(),
        _dados.estacoes(),
        _dados.alertas(),
        _dados.regioesSeguidas(),
        _dados.chuvaUltimaColeta(),
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
    await _canal?.unsubscribe();
    return super.close();
  }
}
