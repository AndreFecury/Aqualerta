// Gera os PNGs do ícone (Android 7.x e anteriores ao ícone adaptativo) e
// o PNG de 512 px. Mesmo desenho de
// android/app/src/main/res/drawable/ic_launcher_foreground.xml.
//
// Rodar só quando o desenho mudar:
//   flutter test tool/gerar_icone_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fundo = Color(0xFF0E5C6B);
const _regua = Color(0xFFFBFCF8);
const _agua = Color(0xE07FCFDE);
const _marca = Color(0xFFE0661B);

/// Desenha no sistema de coordenadas do ícone adaptativo (108 × 108).
void _desenhar(Canvas c) {
  c.drawRect(const Rect.fromLTWH(0, 0, 108, 108), Paint()..color = _fundo);
  c.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(46, 26, 16, 60), const Radius.circular(2)),
      Paint()..color = _regua);
  final marcas = Paint()..color = _fundo;
  for (var i = 0; i < 9; i++) {
    final longa = i.isEven;
    c.drawRect(Rect.fromLTWH(46, 31.0 + i * 6, longa ? 10 : 6, longa ? 2.4 : 2),
        marcas);
  }
  final agua = Path()
    ..moveTo(0, 63)
    ..cubicTo(12, 58.5, 24, 58.5, 36, 63)
    ..cubicTo(48, 67.5, 60, 67.5, 72, 63)
    ..cubicTo(84, 58.5, 96, 58.5, 108, 63)
    ..lineTo(108, 108)
    ..lineTo(0, 108)
    ..close();
  c.drawPath(agua, Paint()..color = _agua);
  final marca = Path()
    ..moveTo(64, 64.5)
    ..lineTo(74, 58.5)
    ..lineTo(74, 70.5)
    ..close();
  c.drawPath(marca, Paint()..color = _marca);
}

/// [recorte]: quanto do quadro de 108 aparece (o ícone adaptativo mostra
/// o miolo de 72). [redondo]: ícone redondo em vez de quadrado arredondado.
Future<List<int>> _png(int px,
    {double recorte = 76, bool redondo = false}) async {
  final gravador = ui.PictureRecorder();
  final c = Canvas(gravador);
  final escala = px / recorte;
  final forma = Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble());
  if (redondo) {
    c.clipPath(Path()..addOval(forma));
  } else {
    c.clipRRect(RRect.fromRectAndRadius(forma, Radius.circular(px * 0.2)));
  }
  c.scale(escala);
  c.translate(-(108 - recorte) / 2, -(108 - recorte) / 2);
  _desenhar(c);
  final img = await gravador.endRecording().toImage(px, px);
  final dados = await img.toByteData(format: ui.ImageByteFormat.png);
  return dados!.buffer.asUint8List();
}

void main() {
  test('gera os PNGs do ícone', () async {
    const tamanhos = {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    };
    const res = 'android/app/src/main/res';
    for (final e in tamanhos.entries) {
      File('$res/mipmap-${e.key}/ic_launcher.png')
          .writeAsBytesSync(await _png(e.value));
      File('$res/mipmap-${e.key}/ic_launcher_round.png')
          .writeAsBytesSync(await _png(e.value, redondo: true));
    }
    // Para a loja / README.
    File('docs/icone_512.png').writeAsBytesSync(await _png(512, recorte: 72));
  });
}
