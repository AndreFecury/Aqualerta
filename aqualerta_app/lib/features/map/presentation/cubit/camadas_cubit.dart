import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aqualerta/core/domain/satelite.dart';
import 'package:aqualerta/features/map/data/satelite_repository.dart';

enum TipoMapa {
  automatico('Automático'),
  carta('Carta'),
  ruas('Ruas'),
  terreno('Terreno'),
  satelite('Satélite'),
  hibrido('Híbrido');

  const TipoMapa(this.rotulo);
  final String rotulo;
}

enum Camada {
  areasAlagadas(
      'Áreas alagadas', 'Eventos registrados, com a área real quando houver'),
  // Desligada por padrão (fora do conjunto padrão de ExibicaoMapa).
  aguaSatelite('Água detectada por satélite',
      'Radar Sentinel-1 (Copernicus). Não vê água sob a floresta'),
  regioes('Regiões monitoradas', 'Bairros e cidades com o nível de risco'),
  estacoes('Estações dos rios', 'Nível do rio na última leitura da ANA'),
  minhaLocalizacao('Minha localização', 'Mostra onde você está no mapa');

  const Camada(this.titulo, this.descricao);
  final String titulo;
  final String descricao;
}

class ExibicaoMapa extends Equatable {
  const ExibicaoMapa({
    this.tipo = TipoMapa.automatico,
    this.camadas = const {
      Camada.areasAlagadas,
      Camada.regioes,
      Camada.estacoes,
      Camada.minhaLocalizacao
    },
  });

  final TipoMapa tipo;
  final Set<Camada> camadas;

  bool mostra(Camada c) => camadas.contains(c);

  @override
  List<Object?> get props => [tipo, camadas];
}

/// Tipo de mapa e camadas, salvos no aparelho.
class CamadasCubit extends Cubit<ExibicaoMapa> {
  CamadasCubit(this._prefs) : super(_ler(_prefs));

  final SharedPreferences _prefs;
  static const _kTipo = 'mapa.tipo';
  static const _kCamadas = 'mapa.camadas';

  static ExibicaoMapa _ler(SharedPreferences p) {
    final tipo =
        TipoMapa.values.where((t) => t.name == p.getString(_kTipo)).firstOrNull;
    final nomes = p.getStringList(_kCamadas);
    return ExibicaoMapa(
      tipo: tipo ?? TipoMapa.automatico,
      camadas: nomes == null
          ? const ExibicaoMapa().camadas
          : {
              for (final c in Camada.values)
                if (nomes.contains(c.name)) c
            },
    );
  }

  Future<void> escolherTipo(TipoMapa tipo) async {
    emit(ExibicaoMapa(tipo: tipo, camadas: state.camadas));
    await _prefs.setString(_kTipo, tipo.name);
  }

  Future<void> alternar(Camada camada) async {
    final novas = {...state.camadas};
    novas.contains(camada) ? novas.remove(camada) : novas.add(camada);
    emit(ExibicaoMapa(tipo: state.tipo, camadas: novas));
    await _prefs.setStringList(_kCamadas, [for (final c in novas) c.name]);
  }
}

// ---------------------------------------------------------------------------
// Água detectada por satélite
// ---------------------------------------------------------------------------

enum SituacaoSatelite { carregando, pronto, erro }

class DadoSatelite extends Equatable {
  const DadoSatelite(this.situacao, {this.observacao, this.buscadoEm});
  final SituacaoSatelite situacao;

  /// `null` com [SituacaoSatelite.pronto] = região sem observação ainda.
  final ObservacaoSatelite? observacao;
  final DateTime? buscadoEm;

  @override
  List<Object?> get props => [situacao, observacao, buscadoEm];
}

/// Última observação de satélite por região, guardada em memória. Não busca
/// de novo a mesma região antes de [validadeCache] (o satélite passa a cada
/// 6–12 dias; o banco é verificado a cada 6 h).
class SateliteCubit extends Cubit<Map<String, DadoSatelite>> {
  SateliteCubit(this._fonte, {DateTime Function()? relogio})
      : _agora = relogio ?? DateTime.now,
        super(const {});

  final FonteSatelite _fonte;
  final DateTime Function() _agora;
  static const validadeCache = Duration(minutes: 30);

  DadoSatelite? de(String regionId) => state[regionId];

  /// Busca a região se não estiver em memória (ou se [forcar], no "Tentar
  /// de novo"). Uma busca por vez por região; erro não repete sozinho.
  Future<void> carregar(String regionId, {bool forcar = false}) async {
    final atual = state[regionId];
    if (atual?.situacao == SituacaoSatelite.carregando) return;
    if (!forcar &&
        atual?.situacao == SituacaoSatelite.pronto &&
        _agora().difference(atual!.buscadoEm!) < validadeCache) {
      return;
    }
    if (!forcar && atual?.situacao == SituacaoSatelite.erro) return;
    _por(regionId, const DadoSatelite(SituacaoSatelite.carregando));
    try {
      final obs = await _fonte.ultima(regionId);
      _por(
          regionId,
          DadoSatelite(SituacaoSatelite.pronto,
              observacao: obs, buscadoEm: _agora()));
    } catch (_) {
      _por(regionId, DadoSatelite(SituacaoSatelite.erro, buscadoEm: _agora()));
    }
  }

  void _por(String id, DadoSatelite d) {
    if (isClosed) return;
    emit({...state, id: d});
  }
}
