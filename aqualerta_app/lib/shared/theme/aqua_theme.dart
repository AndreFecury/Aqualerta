import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'aqua_colors.dart';

/// Temas da v3: claro (padrão de dia) e "noite no rio".
///
/// Escala de texto (em pontos lógicos, multiplicada pelo tamanho de letra do
/// celular e pela escolha do usuário no Perfil):
/// leitura da régua 44 · título de tela 24 · seção 19 · item 15–17 ·
/// texto 15 · legenda 13 (mínimo para informação).
abstract class AquaTheme {
  static const fonte = 'AtkinsonHyperlegibleNext';

  static ThemeData get claro => _construir(AquaColors.claro, Brightness.light);
  static ThemeData get escuro => _construir(AquaColors.escuro, Brightness.dark);

  static ThemeData _construir(AquaColors c, Brightness brilho) {
    final escuro = brilho == Brightness.dark;
    final esquema = ColorScheme(
      brightness: brilho,
      primary: c.canal,
      onPrimary: c.sobreCanal,
      secondary: c.canal,
      onSecondary: c.sobreCanal,
      error: c.textoRisco.values.last,
      onError: escuro ? c.fundo : Colors.white,
      surface: c.papel,
      onSurface: c.tinta,
      onSurfaceVariant: c.tinta2,
      outline: c.tinta2,
      outlineVariant: c.linha,
      shadow: c.sombra,
    );

    final textos = _textos(c);
    final cantoBotao =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

    return ThemeData(
      useMaterial3: true,
      brightness: brilho,
      colorScheme: esquema,
      fontFamily: fonte,
      textTheme: textos,
      scaffoldBackgroundColor: c.fundo,
      extensions: [c],
      // Toques de no mínimo 48 px em todo controle.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,

      appBarTheme: AppBarTheme(
        backgroundColor: c.papel,
        foregroundColor: c.tinta,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textos.titleLarge,
        shape: Border(bottom: BorderSide(color: c.linha)),
        systemOverlayStyle:
            escuro ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.papel,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((estados) {
          final ativo = estados.contains(WidgetState.selected);
          return textos.labelMedium!.copyWith(
            color: ativo ? c.tinta : c.tinta2,
            fontWeight: ativo ? FontWeight.w800 : FontWeight.w500,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((estados) => IconThemeData(
              size: 22,
              color:
                  estados.contains(WidgetState.selected) ? c.canal : c.tinta2,
            )),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.canal,
          foregroundColor: c.sobreCanal,
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: cantoBotao,
          textStyle: textos.labelLarge,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.canal,
          foregroundColor: c.sobreCanal,
          elevation: 0,
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: cantoBotao,
          textStyle: textos.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.canal,
          minimumSize: const Size(48, 52),
          side: BorderSide(color: c.canal, width: 1.5),
          shape: cantoBotao,
          textStyle: textos.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.canal,
          minimumSize: const Size(48, 48),
          textStyle: textos.labelLarge,
        ),
      ),

      // A v3 evita cartões com sombra: quando necessário, papel com borda fina.
      cardTheme: CardThemeData(
        color: c.papel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: c.linha),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.papel,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: c.tinta2.withValues(alpha: 0.5),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.papel,
        hintStyle: textos.bodyLarge!.copyWith(color: c.tinta2),
        labelStyle: textos.bodyLarge!.copyWith(color: c.tinta2),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.linha),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.linha),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.canal, width: 2),
        ),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(c.papel),
        trackColor: WidgetStateProperty.resolveWith(
            (e) => e.contains(WidgetState.selected) ? c.canal : c.tinta2),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),

      dividerTheme: DividerThemeData(color: c.linha, thickness: 1, space: 1),
      iconTheme: IconThemeData(color: c.tinta, size: 22),
    );
  }

  static TextTheme _textos(AquaColors c) {
    TextStyle t(double tamanho, FontWeight peso,
            {Color? cor, double altura = 1.3, double espaco = 0}) =>
        TextStyle(
          fontFamily: fonte,
          fontSize: tamanho,
          fontWeight: peso,
          height: altura,
          letterSpacing: espaco,
          color: cor ?? c.tinta,
          // Números de largura fixa: as leituras da régua não "dançam".
          fontFeatures: const [FontFeature.tabularFigures()],
        );

    return TextTheme(
      displaySmall: t(44, FontWeight.w800, altura: 1.0, espaco: -1.5),
      headlineSmall: t(24, FontWeight.w800, altura: 1.15, espaco: -0.3),
      titleLarge: t(19, FontWeight.w800, altura: 1.2),
      titleMedium: t(17, FontWeight.w800),
      titleSmall: t(15, FontWeight.w800),
      bodyLarge: t(15, FontWeight.w400, altura: 1.45),
      bodyMedium: t(14, FontWeight.w400, altura: 1.45),
      bodySmall: t(13, FontWeight.w400, cor: c.tinta2, altura: 1.4),
      labelLarge: t(16, FontWeight.w700, altura: 1.2),
      labelMedium: t(13, FontWeight.w500, altura: 1.2),
      labelSmall: t(13, FontWeight.w700, cor: c.tinta2, altura: 1.2),
    );
  }
}
