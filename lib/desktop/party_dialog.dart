import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../design/gaze_motion.dart';
import '../party/party_api.dart';
import '../party/party_controller.dart';

Future<void> showPartyDialog(
  BuildContext context,
  PartyController controller, {
  String? invite,
}) => showDialog<void>(
  context: context,
  animationStyle: GazeMotion.style(context),
  builder: (_) => _PartyDialog(controller: controller, invite: invite),
);

class _PartyDialog extends StatefulWidget {
  const _PartyDialog({required this.controller, this.invite});
  final PartyController controller;
  final String? invite;
  @override
  State<_PartyDialog> createState() => _PartyDialogState();
}

class _PartyDialogState extends State<_PartyDialog> {
  late final _link = TextEditingController(text: widget.invite);
  final _name = TextEditingController();
  String? _error;
  bool _copied = false;
  @override
  void dispose() {
    _link.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final party = widget.controller;
      return AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(28, 24, 12, 0),
        contentPadding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
        title: Row(
          children: [
            const Icon(Icons.group_rounded, size: 24),
            const SizedBox(width: 12),
            const Expanded(child: Text('Party Session')),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: GazeSwap(
              child: Column(
                key: ValueKey(party.active),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (party.active) ...[
                    Text(
                      party.hosting
                          ? 'Your music, together.'
                          : 'Listening with ${party.hostName}',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      party.hosting
                          ? 'Share the invite with your friends. Everyone can add songs, skip, and edit the queue. Volume stays personal.'
                          : 'Add songs and shape the queue together. Your own queue will be here when you leave.',
                    ),
                    const SizedBox(height: 20),
                    if (party.inviteUrl != null) ...[
                      SelectableText(
                        party.inviteUrl!,
                        style: const TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: party.inviteUrl!),
                          );
                          if (mounted) setState(() => _copied = true);
                        },
                        icon: Icon(
                          _copied ? Icons.check_rounded : Icons.link_rounded,
                        ),
                        label: Text(_copied ? 'Invite copied' : 'Copy invite'),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      '${party.listeners.length} ${party.listeners.length == 1 ? 'listener' : 'listeners'}${party.connected ? ' · Connected' : ' · Reconnecting'}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    if (party.listeners.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final name in party.listeners)
                              Chip(label: Text(name)),
                          ],
                        ),
                      ),
                    const SizedBox(height: 20),
                    OutlinedButton(
                      onPressed: party.busy
                          ? null
                          : () async {
                              await party.leave();
                              if (mounted) setState(() => _copied = false);
                            },
                      child: Text(
                        party.hosting ? 'End session' : 'Leave session',
                      ),
                    ),
                  ] else ...[
                    Text(
                      'Same song. Different places.',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Invite friends to listen along, or join a session with a link. Guests don’t need a library account.',
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: party.busy || !party.canHost
                          ? null
                          : party.start,
                      icon: const Icon(Icons.ios_share_rounded, size: 20),
                      label: const Text('Share my queue'),
                    ),
                    if (!party.canHost)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'To host, connect your gaze service and play library music.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _link,
                      enabled: !party.busy,
                      decoration: const InputDecoration(
                        labelText: 'Invitation link',
                        hintText: 'https://…/party/…',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _name,
                      enabled: !party.busy,
                      maxLength: 40,
                      decoration: const InputDecoration(
                        labelText: 'Your display name',
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: party.busy
                          ? null
                          : () async {
                              setState(() => _error = null);
                              try {
                                await party.join(
                                  PartyInvite.parse(_link.text),
                                  _name.text,
                                );
                              } on PartyException catch (error) {
                                if (mounted)
                                  setState(() => _error = error.message);
                              }
                            },
                      child: const Text('Join session'),
                    ),
                  ],
                  if (party.busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_error != null || party.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        _error ?? party.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
