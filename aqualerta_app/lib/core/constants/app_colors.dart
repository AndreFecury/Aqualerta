import 'package:flutter/material.dart';

abstract class AppColors {
  // ── BACKGROUNDS ──────────────────────────────────────
  static const bg0 = Color(0xFF060B14);
  static const bg1 = Color(0xFF0D1526);
  static const bg2 = Color(0xFF131D33);
  static const bg3 = Color(0xFF1A2540);
  static const bgSheet = Color(0xFF0F1A2E);

  // ── TEXTO ─────────────────────────────────────────────
  static const textPrimary = Color(0xFFEBF0FF);
  static const textSecondary = Color(0xFF7A8FAF);
  static const textDisabled = Color(0xFF3A4E6A);
  static const textAccent = Color(0xFF4D9EFF);

  // ── BRAND ─────────────────────────────────────────────
  static const brandPrimary = Color(0xFF1A7BFF);
  // Corrigido: usar 8 dígitos hex (0xAARRGGBB)
  static const brandGlow = Color(0x331A7BFF);
  static const brandSecondary = Color(0xFF00D4FF);

  // ── ÁGUA ──────────────────────────────────────────────
  static const waterDeep = Color(0xFF003580);
  static const waterMid = Color(0xFF0057CC);
  static const waterFlood = Color(0xFF0085FF);
  static const waterShallow = Color(0xFF29B6F6);

  // ── SEVERIDADE ────────────────────────────────────────
  static const sevLow = Color(0xFF22D65F);
  static const sevMedium = Color(0xFFF5B800);
  static const sevHigh = Color(0xFFFF4545);
  static const sevCritical = Color(0xFFBF35FF);

  // Corrigido: todos com 8 dígitos hex
  static const sevLowBg = Color(0x2022D65F);
  static const sevMediumBg = Color(0x20F5B800);
  static const sevHighBg = Color(0x20FF4545);
  static const sevCriticalBg = Color(0x20BF35FF);

  // ── BORDAS / DIVISÓRIAS ───────────────────────────────
  static const border = Color(0xFF1C2E4A);
  static const borderBright = Color(0xFF243752);
  static const divider = Color(0xFF0F1E35);

  // ── STATUS ────────────────────────────────────────────
  static const success = Color(0xFF22D65F);
  static const warning = Color(0xFFF5B800);
  static const error = Color(0xFFFF4545);
  static const info = Color(0xFF1A7BFF);

  static Color bySeverity(String severity) {
    switch (severity.toUpperCase()) {
      case 'LOW':      return sevLow;
      case 'MEDIUM':   return sevMedium;
      case 'HIGH':     return sevHigh;
      case 'CRITICAL': return sevCritical;
      default:         return sevMedium;
    }
  }

  static Color bySeverityBg(String severity) {
    switch (severity.toUpperCase()) {
      case 'LOW':      return sevLowBg;
      case 'MEDIUM':   return sevMediumBg;
      case 'HIGH':     return sevHighBg;
      case 'CRITICAL': return sevCriticalBg;
      default:         return sevMediumBg;
    }
  }
}
