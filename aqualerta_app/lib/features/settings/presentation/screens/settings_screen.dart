import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:aqualerta/core/constants/app_colors.dart';
import 'package:aqualerta/core/constants/app_typography.dart';
import 'package:aqualerta/core/constants/app_spacing.dart';
import 'package:aqualerta/core/network/supabase_service.dart';
// ignore: unused_import
import 'package:aqualerta/shared/widgets/shared_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pushEnabled = true;
  bool _soundEnabled = true;
  String _minSeverity = 'MEDIUM';
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() => _appVersion = info.version);
  }

  @override
  Widget build(BuildContext context) {
    final user = SupabaseService.currentUser;

    return Scaffold(
      backgroundColor: AppColors.bg0,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(user),
            _buildSection(
              title: 'NOTIFICAÇÕES',
              children: [
                _buildToggle(
                  icon: Icons.notifications_rounded,
                  label: 'Push notifications',
                  subtitle: 'Alertas em tempo real',
                  value: _pushEnabled,
                  onChanged: (v) => setState(() => _pushEnabled = v),
                ),
                _buildDivider(),
                _buildToggle(
                  icon: Icons.volume_up_rounded,
                  label: 'Som de alerta',
                  subtitle: 'Toca som ao receber alertas críticos',
                  value: _soundEnabled,
                  onChanged: (v) => setState(() => _soundEnabled = v),
                ),
                _buildDivider(),
                _buildSeveritySelector(),
              ],
            ),
            _buildSection(
              title: 'SOBRE O APP',
              children: [
                _buildInfoRow(
                  icon: Icons.info_outline_rounded,
                  label: 'Versão',
                  value: _appVersion,
                ),
                _buildDivider(),
                _buildInfoRow(
                  icon: Icons.satellite_alt_rounded,
                  label: 'Fonte de dados',
                  value: 'Copernicus / ANA',
                ),
                _buildDivider(),
                _buildInfoRow(
                  icon: Icons.storage_rounded,
                  label: 'Backend',
                  value: 'Supabase',
                ),
              ],
            ),
            _buildSection(
              title: 'SISTEMA',
              children: [
                _buildActionRow(
                  icon: Icons.refresh_rounded,
                  label: 'Limpar cache',
                  onTap: _clearCache,
                ),
                _buildDivider(),
                _buildActionRow(
                  icon: Icons.bug_report_outlined,
                  label: 'Reportar problema',
                  onTap: () {},
                ),
              ],
            ),
            _buildLogoutButton(user),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(User? user) {
    return Container(
      color: AppColors.bg1,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + AppSpacing.md,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        bottom: AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.bg3,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.settings_rounded,
                    size: 18, color: AppColors.textSecondary),
              ),
              const SizedBox(width: 10),
              const Text('Configurações', style: AppTypography.h2),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          // Perfil
          Row(
            children: [
              // Avatar
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.waterMid, AppColors.brandPrimary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                ),
                child: Center(
                  child: Text(
                    _initials(user?.email ?? 'U'),
                    style: AppTypography.h2.copyWith(color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user?.userMetadata?['display_name'] as String? ??
                        'Usuário',
                    style: AppTypography.title,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user?.email ?? 'Não autenticado',
                    style: AppTypography.caption,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSection(
      {required String title, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.xl,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.label),
          const SizedBox(height: AppSpacing.sm),
          Container(
            decoration: BoxDecoration(
              color: AppColors.bg2,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Widget _buildToggle({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypography.body),
                Text(subtitle, style: AppTypography.caption),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _buildSeveritySelector() {
    final options = {
      'LOW': 'Baixo+',
      'MEDIUM': 'Médio+',
      'HIGH': 'Alto+',
      'CRITICAL': 'Crítico',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune_rounded,
                  size: 20, color: AppColors.textSecondary),
              SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Severidade mínima', style: AppTypography.body),
                    Text('Notificar apenas a partir de',
                        style: AppTypography.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: options.entries.map((e) {
              final isActive = _minSeverity == e.key;
              final color = AppColors.bySeverity(e.key);
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _minSeverity = e.key),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: isActive
                            ? color.withValues(alpha: 0.15)
                            : AppColors.bg3,
                        borderRadius:
                            BorderRadius.circular(AppSpacing.radiusSm),
                        border: Border.all(
                          color: isActive ? color : AppColors.border,
                          width: isActive ? 1.5 : 1,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          e.value,
                          style: AppTypography.caption.copyWith(
                            color: isActive ? color : AppColors.textSecondary,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
      {required IconData icon,
      required String label,
      required String value}) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.md),
          Text(label, style: AppTypography.body),
          const Spacer(),
          Text(value,
              style: AppTypography.body
                  .copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildActionRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Text(label, style: AppTypography.body),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: AppColors.textDisabled),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(
        height: 1, indent: AppSpacing.lg + 20 + AppSpacing.md);
  }

  Widget _buildLogoutButton(User? user) {
    if (user == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _confirmLogout,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.error,
            side: const BorderSide(color: AppColors.error),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
          ),
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: const Text('Sair da conta'),
        ),
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('Sair da conta', style: AppTypography.h3),
        content: Text('Deseja realmente sair?',
            style: AppTypography.body
                .copyWith(color: AppColors.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Sair'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await SupabaseService.auth.signOut();
    }
  }

  Future<void> _clearCache() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Cache limpo com sucesso'),
        backgroundColor: AppColors.sevLow,
      ),
    );
  }

  String _initials(String email) {
    final parts = email.split('@')[0].split('.');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return email.substring(0, 2).toUpperCase();
  }
}
