import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TipoMapa {
  automatico('Automático'),
  carta('Carta'),
  ruas('Ruas'),
  satelite('Satélite');

  const TipoMapa(this.rotulo);
  final String rotulo;
}

enum Camada {
  areasAlagadas('Áreas alagadas', 'Eventos registrados, com a área real quando houver'),
  regioes('Regiões monitoradas', 'Bairros e cidades com o nível de risco'),
  estacoes('Estações dos rios', 'Réguas da ANA com a última leitura'),
  minhaLocalizacao('Minha localização', 'Mostra onde você está no mapa');

  const Camada(this.titulo, this.descricao);
  final String titulo;
  final String descricao;
}

class ExibicaoMapa extends Equatable {
  const ExibicaoMapa({
    this.tipo = TipoMapa.automatico,
    this.camadas = const {Camada.areasAlagadas, Camada.regioes, Camada.estacoes, Camada.minhaLocalizacao},
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
    final tipo = TipoMapa.values.where((t) => t.name == p.getString(_kTipo)).firstOrNull;
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
