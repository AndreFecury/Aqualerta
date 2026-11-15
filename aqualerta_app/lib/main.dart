import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Força orientação portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Status bar transparente
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0D1526),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Inicializa Supabase
  // Substitua pelos valores do seu projeto em https://app.supabase.com
  await Supabase.initialize(
    url: const String.fromEnvironment(
      'SUPABASE_URL',
      defaultValue: 'https://gayykjlkdtmmzovdbjkb.supabase.co',
    ),
    anonKey: const String.fromEnvironment(
      'SUPABASE_ANON_KEY',
      defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdheXlramxrZHRtbXpvdmRiamtiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk3NjI5NjQsImV4cCI6MjA5NTMzODk2NH0.0_NJrYR5NvoWDlMS3qpjnSGdsthWwhqgWDFPetHCIgI',
    ),
    debug: false,
  );

  final preferencias = await SharedPreferences.getInstance();

  runApp(AqualertaApp(preferencias: preferencias));
}
