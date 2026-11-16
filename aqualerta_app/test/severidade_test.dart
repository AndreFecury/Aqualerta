import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/domain/severidade.dart';

void main() {
  // Cotas oficiais do SGB.
  const manaus = CotasEstacao(alerta: 27, inundacao: 27.5, severa: 29);
  const portoVelho = CotasEstacao(alerta: 15, inundacao: 17);

  group('severidadePorCota', () {
    test('abaixo da cota de alerta é Baixo', () {
      expect(severidadePorCota(16.14, manaus), Severidade.baixo);
      expect(severidadePorCota(26.99, manaus), Severidade.baixo);
    });

    test('da cota de alerta até antes da inundação é Médio', () {
      expect(severidadePorCota(27, manaus), Severidade.medio);
      expect(severidadePorCota(27.49, manaus), Severidade.medio);
    });

    test('da cota de inundação até antes da severa é Alto', () {
      expect(severidadePorCota(27.5, manaus), Severidade.alto);
      expect(severidadePorCota(28.9, manaus), Severidade.alto);
    });

    test('a partir da inundação severa é Crítico', () {
      expect(severidadePorCota(29, manaus), Severidade.critico);
      expect(severidadePorCota(30.02, manaus), Severidade.critico);
    });

    test('sem cota severa, o máximo é Alto', () {
      expect(severidadePorCota(15.2, portoVelho), Severidade.medio);
      expect(severidadePorCota(19.7, portoVelho), Severidade.alto);
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
