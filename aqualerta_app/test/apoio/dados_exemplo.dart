import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/data/carta_datasource.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';

/// Dados de exemplo baseados no seed do schema.sql, para testes de tela.
class CartaFalsa extends CartaDatasource {
  CartaFalsa() : super(SupabaseClient('http://localhost', 'chave-de-teste',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  final agora = DateTime.now();

  static const compensa = Regiao(
    id: 'r-compensa',
    nome: 'Compensa',
    uf: 'AM',
    municipio: 'Manaus',
    centro: LatLng(-3.105, -60.06),
    contornos: [
      [LatLng(-3.09, -60.08), LatLng(-3.09, -60.04), LatLng(-3.12, -60.04), LatLng(-3.12, -60.08)],
    ],
  );
  static const centro = Regiao(
    id: 'r-centro',
    nome: 'Centro',
    uf: 'AM',
    municipio: 'Manaus',
    centro: LatLng(-3.13, -60.02),
    contornos: [
      [LatLng(-3.12, -60.03), LatLng(-3.12, -60.01), LatLng(-3.14, -60.01), LatLng(-3.14, -60.03)],
    ],
  );
  static const portoVelho = Regiao(id: 'r-pvh', nome: 'Porto Velho', uf: 'RO', centro: LatLng(-8.76, -63.9));

  @override
  Future<List<Regiao>> regioes() async => const [compensa, centro, portoVelho];

  @override
  Future<List<Evento>> eventos() async => [
        Evento(
          id: 'e1',
          regiaoId: compensa.id,
          regiaoNome: 'Compensa, AM',
          detectadoEm: agora.subtract(const Duration(hours: 2)),
          severidade: Severidade.alto,
          contornos: compensa.contornos,
        ),
      ];

  @override
  Future<List<Estacao>> estacoes() async => [
        Estacao(
          id: 's1',
          codigoAna: '14390000',
          nome: 'Manaus',
          rio: 'Rio Negro',
          posicao: const LatLng(-3.1319, -60.0212),
          cotas: const CotasEstacao(normal: 22, alerta: 27, inundacao: 29, emergencia: 29.5),
          nivel: 27.3,
          lidoEm: agora.subtract(const Duration(minutes: 12)),
        ),
        Estacao(
          id: 's2',
          codigoAna: '15400000',
          nome: 'Porto Velho',
          rio: 'Rio Madeira',
          posicao: const LatLng(-8.7612, -63.9068),
          cotas: const CotasEstacao(normal: 11, alerta: 14, inundacao: 17, emergencia: 17.5),
          nivel: 15.2,
          lidoEm: agora.subtract(const Duration(hours: 5)),
        ),
        const Estacao(
          id: 's3',
          codigoAna: '17050001',
          nome: 'Óbidos',
          rio: 'Rio Amazonas',
          posicao: LatLng(-1.9177, -55.5177),
          cotas: CotasEstacao(normal: 7, alerta: 10, inundacao: 11.5, emergencia: 12),
        ),
      ];

  @override
  Future<List<AlertaV3>> alertas() async => [
        AlertaV3(
          id: 'a1',
          regiaoId: compensa.id,
          regiaoNome: 'Compensa, AM',
          titulo: 'Nível do Rio Negro acima do normal',
          texto: 'O rio Negro em Manaus atingiu 27,3 m, acima do nível de alerta (27 m). Monitoramento intensificado.',
          severidadeOriginal: Severidade.alto,
          ativo: true,
          emitidoEm: agora.subtract(const Duration(hours: 2)),
          eventoId: 'e1',
        ),
        AlertaV3(
          id: 'a2',
          regiaoId: portoVelho.id,
          regiaoNome: 'Porto Velho, RO',
          titulo: 'Rio Madeira com elevação significativa',
          texto: 'Estação de Porto Velho registra 15,2 m. Monitoramento em curso.',
          severidadeOriginal: Severidade.medio,
          ativo: true,
          emitidoEm: agora.subtract(const Duration(hours: 5)),
        ),
        AlertaV3(
          id: 'a3',
          regiaoId: centro.id,
          regiaoNome: 'Centro, AM',
          titulo: 'Chuva forte no Centro',
          texto: 'Alerta encerrado após a chuva parar.',
          severidadeOriginal: Severidade.medio,
          ativo: false,
          emitidoEm: agora.subtract(const Duration(days: 3)),
          encerradoEm: agora.subtract(const Duration(days: 2)),
        ),
      ];

  @override
  Future<Set<String>> regioesSeguidas() async => {compensa.id};

  @override
  Future<void> seguir(String regiaoId, {required bool seguir}) async {}
}
