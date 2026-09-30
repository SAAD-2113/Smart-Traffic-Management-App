import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';

/// Where is the backend? The prototype runs it on a laptop, so the address is configurable.
Future<void> showServerSettings(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ServerSettingsSheet(),
    );

class _ServerSettingsSheet extends StatefulWidget {
  const _ServerSettingsSheet();

  @override
  State<_ServerSettingsSheet> createState() => _ServerSettingsSheetState();
}

class _ServerSettingsSheetState extends State<_ServerSettingsSheet> {
  late final _controller = TextEditingController(text: context.read<AppConfig>().serverUrl);
  String? _error;
  String? _result;
  bool _ok = false;
  bool _testing = false;

  Future<void> _test() async {
    final value = _controller.text.trim().replaceAll(RegExp(r'/+$'), '');
    final problem = AppConfig.validateServerUrl(value);
    setState(() {
      _error = problem;
      _result = null;
    });
    if (problem != null) return;
    setState(() => _testing = true);
    try {
      // A free cloud server that was asleep can take up to a minute to answer its first request.
      final response = await http.get(Uri.parse('$value/api/v1/health')).timeout(const Duration(seconds: 75));
      _ok = response.statusCode == 200 && response.body.contains('"database":"ok"');
      _result = _ok ? 'Connected. The server and its database are running.' : 'The server answered, but reports a problem (${response.statusCode}).';
    } catch (_) {
      _ok = false;
      _result = 'No answer. Check the address. A server on your PC must be running and on the same Wi-Fi; '
          'a cloud server may still be starting, so try again in a minute.';
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    final problem = AppConfig.validateServerUrl(value);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    await context.read<AppConfig>().setServerUrl(value);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final insecure = Uri.tryParse(_controller.text.trim())?.scheme == 'http' &&
        !AppConfig.isPrivateHost(Uri.tryParse(_controller.text.trim())?.host ?? '');
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Server address', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('The address of the Smart Traffic backend: its https:// address when it is hosted in the cloud, '
            'or for example http://192.168.1.20:8000 for a server on your PC on the same Wi-Fi.'),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(labelText: 'Server address', errorText: _error, prefixIcon: const Icon(Icons.dns)),
          onChanged: (_) => setState(() => _result = null),
        ),
        if (insecure) ...[
          const SizedBox(height: 8),
          const Text('Warning: plain http:// to a public address sends data unencrypted. Use https:// outside the lab.',
              style: TextStyle(color: StatusColors.danger)),
        ],
        if (_testing) ...[
          const SizedBox(height: 12),
          const Text('Waiting for the server. A cloud server that was asleep can take up to a minute to wake up.'),
        ],
        if (_result != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Icon(_ok ? Icons.check_circle : Icons.error, color: _ok ? StatusColors.ok : StatusColors.danger),
            const SizedBox(width: 8),
            Expanded(child: Text(_result!)),
          ]),
        ],
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: const Text('Test'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(onPressed: _save, child: const Text('Save'))),
        ]),
      ]),
    );
  }
}
