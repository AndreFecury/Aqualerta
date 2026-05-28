import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/constants/app_colors.dart';
import 'package:aqualerta/core/constants/app_typography.dart';
import 'package:aqualerta/core/constants/app_spacing.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLogin = true;
  bool _loading = false;
  bool _obscurePass = true;
  String? _error;

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _nameCtrl.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg0,
      body: Stack(
        children: [
          // ── Background decorativo ──────────────────────────
          _buildBackground(),

          // ── Conteúdo ───────────────────────────────────────
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: AppSpacing.xxl),
                      _buildLogo(),
                      const SizedBox(height: AppSpacing.xxxl),
                      _buildToggle(),
                      const SizedBox(height: AppSpacing.xl),
                      _buildForm(),
                      const SizedBox(height: AppSpacing.xl),
                      if (_error != null) _buildError(),
                      const SizedBox(height: AppSpacing.lg),
                      _buildSubmitButton(),
                      const SizedBox(height: AppSpacing.lg),
                      _buildSwitchMode(),
                      const SizedBox(height: AppSpacing.xxxl),
                      _buildFooter(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return Stack(
      children: [
        // Gradiente azul escuro
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF060F22), AppColors.bg0],
            ),
          ),
        ),
        // Círculo de glow superior
        Positioned(
          top: -120,
          right: -80,
          child: Container(
            width: 320,
            height: 320,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.waterMid.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // Círculo inferior
        Positioned(
          bottom: -100,
          left: -60,
          child: Container(
            width: 280,
            height: 280,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.brandPrimary.withValues(alpha: 0.12),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // Grid dots decorativos
        Positioned.fill(
          child: CustomPaint(painter: _DotGridPainter()),
        ),
      ],
    );
  }

  Widget _buildLogo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.waterFlood, AppColors.brandPrimary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.brandPrimary.withValues(alpha: 0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(Icons.water_drop_rounded,
                  color: Colors.white, size: 26),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AQUALERTA',
                  style: AppTypography.h1.copyWith(
                    letterSpacing: 3,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  'Monitoramento de Enchentes',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildToggle() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _ToggleTab(
            label: 'Entrar',
            active: _isLogin,
            onTap: () {
              setState(() {
                _isLogin = true;
                _error = null;
              });
            },
          ),
          _ToggleTab(
            label: 'Criar conta',
            active: !_isLogin,
            onTap: () {
              setState(() {
                _isLogin = false;
                _error = null;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          // Nome — só no cadastro
          if (!_isLogin) ...[
            _buildField(
              controller: _nameCtrl,
              label: 'Nome completo',
              hint: 'Ex: Maria Silva',
              icon: Icons.person_outline_rounded,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Informe seu nome' : null,
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          // Email
          _buildField(
            controller: _emailCtrl,
            label: 'E-mail',
            hint: 'seu@email.com',
            icon: Icons.email_outlined,
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Informe o e-mail';
              if (!v.contains('@')) return 'E-mail inválido';
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.md),

          // Senha
          _buildField(
            controller: _passCtrl,
            label: 'Senha',
            hint: _isLogin ? '••••••••' : 'Mínimo 6 caracteres',
            icon: Icons.lock_outline_rounded,
            obscure: _obscurePass,
            validator: (v) {
              if (v == null || v.isEmpty) return 'Informe a senha';
              if (!_isLogin && v.length < 6) {
                return 'Senha precisa ter ao menos 6 caracteres';
              }
              return null;
            },
            suffix: GestureDetector(
              onTap: () => setState(() => _obscurePass = !_obscurePass),
              child: Icon(
                _obscurePass
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    bool obscure = false,
    String? Function(String?)? validator,
    Widget? suffix,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: AppTypography.body,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20, color: AppColors.textSecondary),
        suffixIcon: suffix,
      ),
    );
  }

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.sevHighBg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border:
            Border.all(color: AppColors.sevHigh.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 16, color: AppColors.sevHigh),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: AppTypography.caption
                  .copyWith(color: AppColors.sevHigh),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _loading ? null : _submit,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.brandPrimary,
          disabledBackgroundColor: AppColors.brandPrimary.withValues(alpha: 0.5),
          minimumSize: const Size(double.infinity, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          elevation: 0,
          shadowColor: AppColors.brandPrimary.withValues(alpha: 0.4),
        ),
        child: _loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Text(
                _isLogin ? 'Entrar' : 'Criar conta',
                style: AppTypography.button.copyWith(color: Colors.white),
              ),
      ),
    );
  }

  Widget _buildSwitchMode() {
    return Center(
      child: GestureDetector(
        onTap: () => setState(() {
          _isLogin = !_isLogin;
          _error = null;
        }),
        child: RichText(
          text: TextSpan(
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
            children: [
              TextSpan(
                  text: _isLogin
                      ? 'Não tem conta? '
                      : 'Já tem conta? '),
              TextSpan(
                text: _isLogin ? 'Criar agora' : 'Entrar',
                style: AppTypography.bodyStrong.copyWith(
                  color: AppColors.brandPrimary,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.brandPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Center(
      child: Column(
        children: [
          // Linha divisora com texto
          Row(
            children: [
              const Expanded(
                  child: Divider(color: AppColors.border, thickness: 1)),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Text('dados em tempo real',
                    style: AppTypography.caption
                        .copyWith(color: AppColors.textDisabled)),
              ),
              const Expanded(
                  child: Divider(color: AppColors.border, thickness: 1)),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          // Chips de fonte de dados
          const Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              _DataBadge(label: 'Sentinel-1 SAR', icon: Icons.satellite_alt_rounded),
              _DataBadge(label: 'Copernicus', icon: Icons.public_rounded),
              _DataBadge(label: 'ANA / SNIRH', icon: Icons.water_rounded),
              _DataBadge(label: 'OpenWeather', icon: Icons.cloud_outlined),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_isLogin) {
        await Supabase.instance.client.auth.signInWithPassword(
          email: _emailCtrl.text.trim(),
          password: _passCtrl.text,
        );
      } else {
        await Supabase.instance.client.auth.signUp(
          email: _emailCtrl.text.trim(),
          password: _passCtrl.text,
          data: {'display_name': _nameCtrl.text.trim()},
        );
      }

      if (mounted) context.go('/map');
    } on AuthException catch (e) {
      setState(() => _error = _translateError(e.message));
    } catch (e) {
      setState(() => _error = 'Erro inesperado. Tente novamente.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _translateError(String msg) {
    if (msg.contains('Invalid login credentials')) {
      return 'E-mail ou senha incorretos.';
    }
    if (msg.contains('Email not confirmed')) {
      return 'Confirme seu e-mail antes de entrar.';
    }
    if (msg.contains('User already registered')) {
      return 'Este e-mail já está cadastrado.';
    }
    if (msg.contains('Password should be at least')) {
      return 'Senha precisa ter ao menos 6 caracteres.';
    }
    return msg;
  }
}

// ── Componentes locais ────────────────────────────────────────

class _ToggleTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ToggleTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: active ? AppColors.brandPrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
          child: Center(
            child: Text(
              label,
              style: AppTypography.bodyStrong.copyWith(
                color:
                    active ? Colors.white : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DataBadge extends StatelessWidget {
  final String label;
  final IconData icon;

  const _DataBadge({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.bg2,
        borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: AppColors.textDisabled),
          const SizedBox(width: 5),
          Text(label,
              style: AppTypography.label.copyWith(
                  color: AppColors.textDisabled, fontSize: 10)),
        ],
      ),
    );
  }
}

// ── Dot grid painter ──────────────────────────────────────────
class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.border.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    const spacing = 28.0;
    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_) => false;
}
