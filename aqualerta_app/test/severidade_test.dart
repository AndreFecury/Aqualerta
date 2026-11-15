import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/domain/severidade.dart';

void main() {
  // Cotas reais do seed (supabase/schema.sql).
  const manaus = CotasEstacao(normal: 22, alerta: 27, inundacao: 29, emergencia: 29.5);
  const portoVelho = CotasEstacao(normal: 11, alerta: 14, inundacao: 17, emergencia: 17.5);

  group('severidadePorCota', () {
    test('abaixo da cota normal é Baixo', () {
      expect(severidadePorCota(21.9, manaus), Severidade.baixo);
    });

    test('da cota normal até antes do alerta é Médio', () {
      expect(severidadePorCota(22, manaus), Severidade.medio);
      expect(severidadePorCota(26.99, manaus), Severidade.medio);
    });

    test('da cota de alerta até antes da inundação é Alto', () {
      expect(severidadePorCota(27, manaus), Severidade.alto);
      expect(severidadePorCota(27.3, manaus), Severidade.alto);
    });

    test('a partir da cota de inundação é Crítico', () {
      expect(severidadePorCota(29, manaus), Severidade.critico);
      expect(severidadePorCota(30.1, manaus), Severidade.critico);
    });

    test('Porto Velho a 15,2 m é Alto, e não Médio como no seed', () {
      expect(severidadePorCota(15.2, portoVelho), Severidade.alto);
    });
  });

  group('Severidade.doCodigo', () {
    test('lê os códigos do banco', () {
      expect(Severidade.doCodigo('LOW'), Severidade.baixo);
      expect(Severidade.doCodigo('medium'), Severidade.medio);
      expect(Severidade.doCodigo(' HIGH '), Severidade.alto);
      expect(Severidade.doCodigo('CRITICAL'), Severidade.critico);
    });

    test('valor desconhecido vira Médio para nunca esconder um alerta', () {
      expect(Severidade.doCodigo(null), Severidade.medio);
      expect(Severidade.doCodigo('???'), Severidade.medio);
    });

    test('compara níveis', () {
      expect(Severidade.critico >= Severidade.alto, isTrue);
      expect(Severidade.baixo >= Severidade.medio, isFalse);
    });
  });
}
