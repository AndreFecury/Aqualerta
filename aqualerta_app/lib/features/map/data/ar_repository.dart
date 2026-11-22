import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/domain/ar.dart';

/// De onde vem a qualidade do ar das regiões.
abstract class FonteAr {
  /// Uma linha por região monitorada. Lança em erro de rede.
  Future<List<ResumoAr>> resumo();

  /// Última coleta bem-sucedida do modelo (`ar_estado`); `null` se nunca.
  Future<DateTime?> ultimaColeta();
}

/// Lê a RPC `ar_resumo` e a tabela `ar_estado`
/// (supabase/migrations/20261122_ar.sql), preenchidas pelo próprio banco com
/// o modelo CAMS (Open-Meteo) e os focos do INPE.
class ArRepository implements FonteAr {
  ArRepository([SupabaseClient? cliente]) : _cliente = cliente;
  final SupabaseClient? _cliente;
  SupabaseClient get _c => _cliente ?? Supabase.instance.client;

  @override
  Future<List<ResumoAr>> resumo() async {
    final linhas = await _c.rpc('ar_resumo') as List;
    final resumos = [
      for (final l in linhas) ResumoAr.doJson(l as Map<String, dynamic>)
    ];
    // Contexto (sensor, comparação, cautela) é um extra: sem ele, só o modelo.
    final contextos = <String, ContextoAr>{};
    try {
      for (final l in await _c.rpc('ar_contexto') as List) {
        final m = ContextoAr.doJson(l as Map<String, dynamic>);
        contextos[m.regiaoId] = m;
      }
    } catch (_) {}
    return [for (final r in resumos) r.comContexto(contextos[r.regiaoId])];
  }

  @override
  Future<DateTime?> ultimaColeta() async {
    final r = await _c.from('ar_estado').select('modelo_ok_em').maybeSingle();
    final v = r?['modelo_ok_em'] as String?;
    return v == null ? null : DateTime.parse(v);
  }
}

enum SituacaoAr { carregando, pronto, erro }

class EstadoAr extends Equatable {
  const EstadoAr(this.situacao,
      {this.regioes = const {}, this.buscadoEm, this.coletaEm});
  final SituacaoAr situacao;
  final Map<String, ResumoAr> regioes;
  final DateTime? buscadoEm;

  /// Última coleta do modelo no servidor (para o Perfil).
  final DateTime? coletaEm;

  ResumoAr? de(String regiaoId) => regioes[regiaoId];

  @override
  List<Object?> get props => [situacao, regioes, buscadoEm, coletaEm];
}

/// Qualidade do ar de todas as regiões numa busca só (a RPC devolve as 6),
/// guardada em memória por [validadeCache]: o modelo só muda de hora em hora.
class ArCubit extends Cubit<EstadoAr> {
  ArCubit(this._fonte, {DateTime Function()? relogio})
      : _agora = relogio ?? DateTime.now,
        super(const EstadoAr(SituacaoAr.carregando));

  final FonteAr _fonte;
  final DateTime Function() _agora;
  static const validadeCache = Duration(minutes: 30);
  bool _buscando = false;

  bool get vencido =>
      state.buscadoEm == null ||
      _agora().difference(state.buscadoEm!) >= validadeCache;

  Future<void> carregar({bool forcar = false}) async {
    if (_buscando) return;
    if (!forcar && state.situacao == SituacaoAr.pronto && !vencido) return;
    if (!forcar && state.situacao == SituacaoAr.erro) return;
    _buscando = true;
    if (state.regioes.isEmpty) {
      _emitir(EstadoAr(SituacaoAr.carregando, coletaEm: state.coletaEm));
    }
    try {
      final lista = await _fonte.resumo();
      DateTime? coleta;
      try {
        coleta = await _fonte.ultimaColeta();
      } catch (_) {}
      _emitir(EstadoAr(SituacaoAr.pronto,
          regioes: {for (final r in lista) r.regiaoId: r},
          buscadoEm: _agora(),
          coletaEm: coleta));
    } catch (_) {
      // Com dados antigos em mãos, mostra-os; sem nada, erro com "Tentar".
      _emitir(state.regioes.isEmpty
          ? EstadoAr(SituacaoAr.erro, buscadoEm: _agora())
          : state);
    } finally {
      _buscando = false;
    }
  }

  void _emitir(EstadoAr e) {
    if (!isClosed) emit(e);
  }
}
