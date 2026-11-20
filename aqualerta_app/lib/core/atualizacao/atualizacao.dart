import 'dart:async';
import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Atualizar o AquaAlerta sem a pessoa procurar APK.
///
/// O site do projeto publica `versao.json` (gerado pelo script de
/// publicação) com o número da versão, o link da APK e o SHA-256 dela:
///
///   {"codigo": 47, "versao": "4.7.0", "apk": "https://…/aqualerta.apk",
///    "sha256": "…64 hex…", "tamanho": 58900000, "notas": "…"}
///
/// O app compara `codigo` com o próprio número de build. Se for maior,
/// oferece "Atualizar": baixa a APK, confere o SHA-256 e abre o instalador
/// do Android, que sempre pede confirmação. O Android ainda recusa qualquer
/// APK que não tenha sido assinada com a mesma chave do app instalado.

class VersaoPublicada extends Equatable {
  const VersaoPublicada({
    required this.codigo,
    required this.versao,
    required this.apk,
    required this.sha256,
    this.tamanho,
    this.notas,
  });

  final int codigo;
  final String versao;
  final Uri apk;
  final String sha256;
  final int? tamanho;
  final String? notas;

  /// Só aceita APK por HTTPS vinda dos endereços do projeto no GitHub.
  static const hostsPermitidos = {
    'andrefecury.github.io',
    'github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
  };

  /// Lê o manifesto; devolve `null` se faltar algo ou parecer errado.
  static VersaoPublicada? doJson(Object? j) {
    if (j is! Map) return null;
    final codigo = j['codigo'];
    final versao = j['versao'];
    final apk = Uri.tryParse('${j['apk'] ?? ''}');
    final sha = '${j['sha256'] ?? ''}'.toLowerCase();
    if (codigo is! int || codigo <= 0) return null;
    if (versao is! String || versao.isEmpty) return null;
    if (apk == null ||
        apk.scheme != 'https' ||
        !hostsPermitidos.contains(apk.host)) {
      return null;
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
    final tamanho = j['tamanho'];
    final notas = j['notas'];
    return VersaoPublicada(
      codigo: codigo,
      versao: versao,
      apk: apk,
      sha256: sha,
      tamanho: tamanho is int && tamanho > 0 ? tamanho : null,
      notas: notas is String && notas.trim().isNotEmpty ? notas.trim() : null,
    );
  }

  /// "57 MB", para a pessoa saber antes de baixar pelos dados móveis.
  String? get tamanhoTexto =>
      tamanho == null ? null : '${(tamanho! / 1000000).round()} MB';

  @override
  List<Object?> get props => [codigo, versao, apk, sha256, tamanho, notas];
}

enum FaseAtualizacao { nada, disponivel, baixando, instalando, erro }

class EstadoAtualizacao extends Equatable {
  const EstadoAtualizacao({
    this.fase = FaseAtualizacao.nada,
    this.nova,
    this.progresso,
    this.erro,
    this.dispensada = false,
  });

  final FaseAtualizacao fase;
  final VersaoPublicada? nova;

  /// 0 a 100 durante o download.
  final int? progresso;
  final String? erro;

  /// "Agora não": some até a próxima abertura do app.
  final bool dispensada;

  bool get mostrarAviso =>
      fase != FaseAtualizacao.nada && nova != null && !dispensada;

  EstadoAtualizacao copyWith({
    FaseAtualizacao? fase,
    VersaoPublicada? nova,
    int? progresso,
    String? erro,
    bool? dispensada,
  }) =>
      EstadoAtualizacao(
        fase: fase ?? this.fase,
        nova: nova ?? this.nova,
        progresso: progresso,
        erro: erro,
        dispensada: dispensada ?? this.dispensada,
      );

  @override
  List<Object?> get props => [fase, nova, progresso, erro, dispensada];
}

/// Evento do download/instalação, independente do plugin (para testes).
class PassoInstalacao {
  const PassoInstalacao(this.fase, {this.progresso, this.erro});
  final FaseAtualizacao fase;
  final int? progresso;
  final String? erro;
}

typedef BuscarManifesto = Future<Object?> Function();
typedef LerCodigoAtual = Future<int> Function();
typedef Instalar = Stream<PassoInstalacao> Function(VersaoPublicada v);

class AtualizacaoCubit extends Cubit<EstadoAtualizacao> {
  AtualizacaoCubit({
    BuscarManifesto? buscar,
    LerCodigoAtual? codigoAtual,
    Instalar? instalar,
  })  : _buscar = buscar ?? _buscarDoSite,
        _codigoAtual = codigoAtual ?? _codigoDoApp,
        _instalar = instalar ?? _instalarComOta,
        super(const EstadoAtualizacao());

  static const urlManifesto =
      'https://andrefecury.github.io/Aqualerta/versao.json';

  final BuscarManifesto _buscar;
  final LerCodigoAtual _codigoAtual;
  final Instalar _instalar;
  StreamSubscription<PassoInstalacao>? _passos;

  /// Confere se há versão nova. Devolve `true` se houver. Sem internet ou
  /// com manifesto estranho, fica quieto (não é motivo para alarmar).
  /// `manual`: a pessoa pediu (Perfil), então o aviso volta mesmo se tinha
  /// sido dispensado.
  Future<bool> verificar({bool manual = false}) async {
    if (state.fase == FaseAtualizacao.baixando ||
        state.fase == FaseAtualizacao.instalando) {
      return true;
    }
    try {
      final v = VersaoPublicada.doJson(await _buscar());
      if (v == null || v.codigo <= await _codigoAtual()) return false;
      emit(EstadoAtualizacao(
          fase: FaseAtualizacao.disponivel,
          nova: v,
          dispensada: !manual && state.dispensada && state.nova == v));
      return true;
    } catch (_) {
      return false;
    }
  }

  void dispensar() => emit(state.copyWith(fase: state.fase, dispensada: true));

  /// Baixa, confere e abre o instalador do Android.
  void atualizar() {
    final v = state.nova;
    if (v == null || state.fase == FaseAtualizacao.baixando) return;
    emit(state.copyWith(fase: FaseAtualizacao.baixando, progresso: 0));
    _passos?.cancel();
    _passos = _instalar(v).listen(
      (p) => emit(
          state.copyWith(fase: p.fase, progresso: p.progresso, erro: p.erro)),
      onError: (_) => emit(state.copyWith(
          fase: FaseAtualizacao.erro,
          erro: 'Não foi possível baixar a atualização. Tente de novo.')),
    );
  }

  @override
  Future<void> close() async {
    await _passos?.cancel();
    return super.close();
  }

  static Future<Object?> _buscarDoSite() async {
    // Evita resposta guardada em cache por proxy da operadora.
    final url = Uri.parse(
        '$urlManifesto?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}');
    final r = await http.get(url).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  static Future<int> _codigoDoApp() async =>
      int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

  static Stream<PassoInstalacao> _instalarComOta(VersaoPublicada v) {
    return OtaUpdate()
        .execute(v.apk.toString(),
            destinationFilename: 'aqualerta.apk', sha256checksum: v.sha256)
        .map((e) => switch (e.status) {
              OtaStatus.DOWNLOADING => PassoInstalacao(FaseAtualizacao.baixando,
                  progresso: int.tryParse(e.value ?? '')),
              OtaStatus.INSTALLING ||
              OtaStatus.INSTALLATION_DONE =>
                const PassoInstalacao(FaseAtualizacao.instalando),
              OtaStatus.CHECKSUM_ERROR =>
                const PassoInstalacao(FaseAtualizacao.erro,
                    erro: 'O arquivo baixado não confere. Nada foi instalado; '
                        'tente de novo.'),
              OtaStatus.PERMISSION_NOT_GRANTED_ERROR =>
                const PassoInstalacao(FaseAtualizacao.erro,
                    erro: 'Permita que o AquaAlerta instale atualizações '
                        '(o Android pergunta uma vez) e tente de novo.'),
              OtaStatus.CANCELED =>
                const PassoInstalacao(FaseAtualizacao.disponivel),
              _ => const PassoInstalacao(FaseAtualizacao.erro,
                  erro:
                      'Não foi possível baixar a atualização. Tente de novo.'),
            });
  }
}
