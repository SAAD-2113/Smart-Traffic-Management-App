import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/validators.dart';
import '../../widgets/common.dart';
import 'auth_controller.dart';

/// Step 1: request a reset link by email. Step 2: paste the token from the link and choose a
/// new password (the prototype has no deep links, so the token is entered by hand).
class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key});

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _emailForm = GlobalKey<FormState>();
  final _resetForm = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _token = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  Future<void> _request() async {
    if (!_emailForm.currentState!.validate()) return;
    setState(() => _busy = true);
    await runGuarded(context, () async {
      final message = await context.read<AuthController>().forgotPassword(_email.text);
      if (mounted) showInfo(context, message);
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reset() async {
    if (!_resetForm.currentState!.validate()) return;
    setState(() => _busy = true);
    var token = _token.text.trim();
    final fromLink = Uri.tryParse(token)?.queryParameters['token'];
    if (fromLink != null) token = fromLink; // the whole link was pasted
    final ok = await runGuarded(
      context,
      () => context.read<AuthController>().resetPassword(token, _password.text),
      success: 'Password changed. Sign in with the new password.',
    );
    if (mounted) setState(() => _busy = false);
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionHeader('1. Get a reset link'),
                Form(
                  key: _emailForm,
                  child: TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Account email', prefixIcon: Icon(Icons.alternate_email)),
                    validator: Validators.email,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _busy ? null : _request, child: const Text('Send reset link')),
                const SectionHeader('2. Choose a new password',
                    subtitle: 'Paste the link (or the token in it) from the email.'),
                Form(
                  key: _resetForm,
                  child: Column(children: [
                    TextFormField(
                      controller: _token,
                      decoration: const InputDecoration(labelText: 'Reset link or token', prefixIcon: Icon(Icons.key)),
                      validator: (v) => Validators.required(v, 'The token'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'New password', prefixIcon: Icon(Icons.lock_outline)),
                      validator: Validators.password,
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _busy ? null : _reset, child: const Text('Set new password')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
