import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

/// Logo do MapTiler, exigido pelo plano gratuito sempre que os mapas dele
/// aparecem. Fica sobre um fundo claro para ser lido também no mapa escuro,
/// e leva ao site do MapTiler.
class LogoMapTiler extends StatelessWidget {
  const LogoMapTiler({super.key});

  static const asset = 'assets/logos/maptiler.svg';
  static final _site = Uri.parse('https://www.maptiler.com/');

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: 'Mapas do MapTiler. Abrir o site do MapTiler',
      excludeSemantics: true,
      child: Material(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () =>
              launchUrl(_site, mode: LaunchMode.externalApplication),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: SvgPicture.asset(asset, height: 18),
          ),
        ),
      ),
    );
  }
}
