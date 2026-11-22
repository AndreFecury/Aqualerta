import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/versao/versao_no_servidor.dart';

void main() {
  test('sem login não envia nada', () async {
    final enviados = <int>[];
    final v = VersaoNoServidor(
        usuario: () => null,
        build: () async => 53,
        enviar: (b) async => enviados.add(b));
    await v.registrar();
    expect(enviados, isEmpty);
  });

  test('envia o build uma vez por conta; outra conta envia de novo', () async {
    final enviados = <int>[];
    var uid = 'a';
    final v = VersaoNoServidor(
        usuario: () => uid,
        build: () async => 53,
        enviar: (b) async => enviados.add(b));
    await v.registrar();
    await v.registrar();
    expect(enviados, [53]);
    uid = 'b';
    await v.registrar();
    expect(enviados, [53, 53]);
  });

  test('erro de rede: tenta de novo na próxima vez', () async {
    var falhar = true;
    final enviados = <int>[];
    final v = VersaoNoServidor(
        usuario: () => 'a',
        build: () async => 53,
        enviar: (b) async {
          if (falhar) throw Exception('sem rede');
          enviados.add(b);
        });
    await v.registrar();
    falhar = false;
    await v.registrar();
    expect(enviados, [53]);
  });

  test('build desconhecido (0) não é enviado', () async {
    final enviados = <int>[];
    final v = VersaoNoServidor(
        usuario: () => 'a',
        build: () async => 0,
        enviar: (b) async => enviados.add(b));
    await v.registrar();
    expect(enviados, isEmpty);
  });
}
