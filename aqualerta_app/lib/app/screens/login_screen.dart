import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/auth/login_google.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/widgets/logo_aqualerta.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _senha = TextEditingController();
  bool _criandoConta = false;
  bool _enviando = false;
  bool _entrandoGoogle = false;
  bool _senhaVisivel = false;
  String? _erro;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _senha.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _enviando = true;
      _erro = null;
      _info = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_criandoConta) {
        final r =
            await auth.signUp(email: _email.text.trim(), password: _senha.text);
        if (r.session == null && mounted) {
          setState(() => _info =
              'Conta criada. Confirme pelo link enviado para ${_email.text.trim()} e depois entre.');
        }
      } else {
        await auth.signInWithPassword(
            email: _email.text.trim(), password: _senha.text);
      }
    } on AuthException catch (e) {
      setState(() => _erro = _traduzir(e));
    } catch (_) {
      setState(() => _erro =
          'Sem conexão com o servidor. Confira a internet e tente de novo.');
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _entrarComGoogle() async {
    setState(() {
      _entrandoGoogle = true;
      _erro = null;
      _info = null;
    });
    try {
      await LoginGoogle.entrar(); // desistir do seletor não é erro
    } catch (_) {
      if (mounted) {
        setState(() => _erro =
            'Não foi possível entrar com o Google. Tente de novo ou use o e-mail.');
      }
    } finally {
      if (mounted) setState(() => _entrandoGoogle = false);
    }
  }

  String _traduzir(AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('invalid login')) return 'E-mail ou senha incorretos.';
    if (m.contains('already registered'))
      return 'Já existe uma conta com esse e-mail. Use "Entrar".';
    if (m.contains('email not confirmed'))
      return 'Confirme o e-mail pelo link que enviamos antes de entrar.';
    if (m.contains('password'))
      return 'A senha precisa ter pelo menos 6 caracteres.';
    return 'Não foi possível ${_criandoConta ? 'criar a conta' : 'entrar'}. Tente de novo.';
  }

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const LogoAqualerta(tamanho: 56),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('AquaAlerta',
                                  style:
                                      t.headlineSmall!.copyWith(fontSize: 30)),
                              Text('Informação que protege',
                                  style:
                                      t.bodyLarge!.copyWith(color: c.tinta2)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Text(
                      'Acompanhe o nível dos rios e receba avisos de cheia na sua região.',
                      style: t.bodyLarge!.copyWith(fontSize: 17),
                    ),
                    const SizedBox(height: 28),
                    if (LoginGoogle.disponivel) ...[
                      // Caminho mais curto: um toque, sem senha.
                      OutlinedButton(
                        key: const Key('entrar-google'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF1F1F1F),
                          side: const BorderSide(color: Color(0xFF747775)),
                        ),
                        onPressed: (_enviando || _entrandoGoogle)
                            ? null
                            : _entrarComGoogle,
                        child: _entrandoGoogle
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Color(0xFF1F1F1F)))
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SvgPicture.asset('assets/logos/google_g.svg',
                                      width: 20,
                                      height: 20,
                                      excludeFromSemantics: true),
                                  const SizedBox(width: 12),
                                  const Flexible(
                                      child: Text('Continuar com o Google')),
                                ],
                              ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(child: Divider(color: c.linha)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text('ou com e-mail', style: t.bodyMedium),
                          ),
                          Expanded(child: Divider(color: c.linha)),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'E-mail'),
                      validator: (v) => (v == null || !v.contains('@'))
                          ? 'Digite um e-mail válido.'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _senha,
                      obscureText: !_senhaVisivel,
                      autofillHints: [
                        _criandoConta
                            ? AutofillHints.newPassword
                            : AutofillHints.password
                      ],
                      onFieldSubmitted: (_) => _enviar(),
                      decoration: InputDecoration(
                        labelText: 'Senha',
                        suffixIcon: IconButton(
                          tooltip: _senhaVisivel
                              ? 'Esconder senha'
                              : 'Mostrar senha',
                          icon: Icon(_senhaVisivel
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () =>
                              setState(() => _senhaVisivel = !_senhaVisivel),
                        ),
                      ),
                      validator: (v) => (v == null || v.length < 6)
                          ? 'A senha precisa ter pelo menos 6 caracteres.'
                          : null,
                    ),
                    if (_erro != null || _info != null) ...[
                      const SizedBox(height: 14),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _erro ?? _info!,
                          style: t.bodyMedium!.copyWith(
                            color: _erro != null
                                ? c.textoRisco.values.last
                                : c.tinta,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed:
                          (_enviando || _entrandoGoogle) ? null : _enviar,
                      child: _enviando
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: c.sobreCanal))
                          : Text(_criandoConta ? 'Criar conta' : 'Entrar'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _enviando
                          ? null
                          : () => setState(() {
                                _criandoConta = !_criandoConta;
                                _erro = null;
                                _info = null;
                              }),
                      child: Text(_criandoConta
                          ? 'Já tenho conta: entrar'
                          : 'Não tenho conta: criar agora'),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Dados de nível dos rios: Agência Nacional de Águas (ANA).',
                      style: t.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
