import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/validators.dart';
import '../../mode/switch_mode.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import 'auth_controller.dart';
import 'password_reset_screen.dart';
import 'register_screen.dart';
import 'server_settings_sheet.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AuthController>().login(_email.text, _password.text);
    } on ApiException catch (e) {
      setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthController>();
    final config = context.watch<AppConfig>();
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: Brand.hero),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: Brand.action,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [BoxShadow(color: Brand.cyan.withValues(alpha: 0.45), blurRadius: 24)],
                      ),
                      child: const Icon(Icons.traffic, size: 46, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Smart Traffic',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  const SizedBox(height: 4),
                  Text('Vehicle data collection and traffic management',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 14.5)),
                  const SizedBox(height: 24),
                  Card(
                    elevation: 8,
                    shadowColor: Colors.black.withValues(alpha: 0.3),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                      child: Form(
                        key: _form,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text('Sign in', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 16),
                          if (auth.notice != null) ...[
                            MessageBanner(text: auth.notice!, color: StatusColors.warning),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email)),
                            validator: Validators.email,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _password,
                            obscureText: _obscure,
                            autofillHints: const [AutofillHints.password],
                            onFieldSubmitted: (_) => _submit(),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                tooltip: _obscure ? 'Show password' : 'Hide password',
                                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                                onPressed: () => setState(() => _obscure = !_obscure),
                              ),
                            ),
                            validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            MessageBanner(text: _error!, color: StatusColors.danger),
                          ],
                          const SizedBox(height: 20),
                          GradientButton(label: 'Sign in', icon: Icons.login, busy: _busy, onPressed: _submit),
                          const SizedBox(height: 8),
                          Wrap(alignment: WrapAlignment.spaceBetween, children: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.push(context, MaterialPageRoute(builder: (_) => const PasswordResetScreen())),
                              child: const Text('Forgot password?'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
                              child: const Text('Create account'),
                            ),
                          ]),
                          const Divider(height: 24),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.dns_outlined),
                            title: const Text('Server'),
                            subtitle: Text(config.serverUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: const Icon(Icons.edit),
                            onTap: () => showServerSettings(context),
                          ),
                          if (auth.notice != null)
                            TextButton.icon(
                              onPressed: () => context.read<AuthController>().init(),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry connection'),
                            ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Center(child: SwitchModeButton(onDark: true)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
