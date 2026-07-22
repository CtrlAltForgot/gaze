import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';
import 'jellyfin_connection_controller.dart';

class JellyfinConnectionScreen extends StatefulWidget {
  const JellyfinConnectionScreen({
    required this.controller,
    required this.onClose,
    super.key,
  });

  final JellyfinConnectionController controller;
  final VoidCallback onClose;

  @override
  State<JellyfinConnectionScreen> createState() =>
      _JellyfinConnectionScreenState();
}

class _JellyfinConnectionScreenState extends State<JellyfinConnectionScreen> {
  final TextEditingController _serverController = TextEditingController();
  final TextEditingController _userNameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool get _usesPlainHttp {
    final uri = Uri.tryParse(_serverController.text.trim());
    return uri?.scheme == 'http';
  }

  @override
  void initState() {
    super.initState();
    _prefillSavedProfile();
  }

  Future<void> _prefillSavedProfile() async {
    final profile = await widget.controller.loadSavedProfile();
    if (!mounted || profile == null) {
      return;
    }
    if (_serverController.text.isEmpty) {
      _serverController.text = profile.serverAddress;
    }
    if (_userNameController.text.isEmpty) {
      _userNameController.text = profile.userName;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _serverController.dispose();
    _userNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    await widget.controller.connect(
      serverAddress: _serverController.text,
      userName: _userNameController.text,
      password: _passwordController.text,
    );
    _passwordController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: widget.onClose,
          tooltip: 'Back to gaze',
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: const Text('Connect Jellyfin'),
      ),
      body: StreamBuilder<JellyfinConnectionState>(
        stream: widget.controller.states,
        initialData: widget.controller.state,
        builder: (context, snapshot) {
          final connection = snapshot.data ?? widget.controller.state;
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(GazeSpacing.large),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: GazeColors.surface,
                    borderRadius: BorderRadius.circular(GazeRadii.card),
                    border: Border.all(color: GazeColors.outline),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(GazeSpacing.xLarge),
                    child: connection.isConnected
                        ? _ConnectedContent(
                            connection: connection,
                            onDisconnect: widget.controller.disconnect,
                          )
                        : _ConnectionForm(
                            connection: connection,
                            serverController: _serverController,
                            userNameController: _userNameController,
                            passwordController: _passwordController,
                            usesPlainHttp: _usesPlainHttp,
                            onServerChanged: (_) => setState(() {}),
                            onConnect: _connect,
                          ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ConnectionForm extends StatelessWidget {
  const _ConnectionForm({
    required this.connection,
    required this.serverController,
    required this.userNameController,
    required this.passwordController,
    required this.usesPlainHttp,
    required this.onServerChanged,
    required this.onConnect,
  });

  final JellyfinConnectionState connection;
  final TextEditingController serverController;
  final TextEditingController userNameController;
  final TextEditingController passwordController;
  final bool usesPlainHttp;
  final ValueChanged<String> onServerChanged;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final connecting = connection.status == JellyfinConnectionStatus.connecting;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Bring your library into gaze',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: GazeSpacing.small),
          const Text(
            'Enter the address and account you already use for Jellyfin. '
            'Your password is never saved.',
          ),
          const SizedBox(height: GazeSpacing.large),
          TextField(
            controller: serverController,
            enabled: !connecting,
            keyboardType: TextInputType.url,
            onChanged: onServerChanged,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Jellyfin server address',
              hintText: 'http://server:8096',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          if (usesPlainHttp) ...[
            const SizedBox(height: GazeSpacing.small),
            const _HttpNotice(),
          ],
          const SizedBox(height: GazeSpacing.medium),
          TextField(
            controller: userNameController,
            enabled: !connecting,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Username',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
          ),
          const SizedBox(height: GazeSpacing.medium),
          TextField(
            controller: passwordController,
            enabled: !connecting,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            onSubmitted: connecting ? null : (_) => onConnect(),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
          ),
          if (connection.errorMessage case final error?) ...[
            const SizedBox(height: GazeSpacing.medium),
            SelectableText(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: GazeSpacing.large),
          FilledButton.icon(
            onPressed: connecting ? null : onConnect,
            icon: connecting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link_rounded),
            label: Text(connecting ? 'Connecting…' : 'Connect'),
          ),
        ],
      ),
    );
  }
}

class _HttpNotice extends StatelessWidget {
  const _HttpNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(GazeSpacing.medium),
      decoration: BoxDecoration(
        color: const Color(0xFF332C1D),
        borderRadius: BorderRadius.circular(GazeRadii.control),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 20),
          SizedBox(width: GazeSpacing.small),
          Expanded(
            child: Text(
              'HTTP is unencrypted. Use it only for a Jellyfin server on '
              'a network you trust.',
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectedContent extends StatelessWidget {
  const _ConnectedContent({
    required this.connection,
    required this.onDisconnect,
  });

  final JellyfinConnectionState connection;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final server = connection.serverInfo!;
    final session = connection.session!;
    final disconnecting =
        connection.status == JellyfinConnectionStatus.disconnecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.check_circle_rounded,
          color: Color(0xFF79C99E),
          size: 44,
        ),
        const SizedBox(height: GazeSpacing.medium),
        Text(
          'Connected to ${server.name}',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: GazeSpacing.small),
        Text(
          'Signed in as ${session.userName} · Jellyfin ${server.version}',
          textAlign: TextAlign.center,
        ),
        if (connection.errorMessage case final error?) ...[
          const SizedBox(height: GazeSpacing.medium),
          SelectableText(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: GazeSpacing.large),
        OutlinedButton(
          onPressed: disconnecting ? null : onDisconnect,
          child: Text(disconnecting ? 'Disconnecting…' : 'Disconnect'),
        ),
      ],
    );
  }
}
