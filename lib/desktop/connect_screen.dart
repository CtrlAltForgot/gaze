import '../design/gaze_motion.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../connect/connect_controller.dart';
import '../design/gaze_theme.dart';
import '../jellyfin/jellyfin_connection_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    required this.controller,
    required this.onClose,
    super.key,
  });
  final ConnectController controller;
  final VoidCallback onClose;
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _address = TextEditingController();
  bool _needsOnly = true;
  @override
  void initState() {
    super.initState();
    _address.text =
        widget.controller.address?.toString() ??
        widget.controller.suggestedAddress;
    if (widget.controller.address == null &&
        widget.controller.connection.state.isConnected &&
        _address.text.isNotEmpty)
      unawaited(widget.controller.connect(_address.text));
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _choosePlaylists() async {
    await widget.controller.loadPlaylists();
    if (!mounted || widget.controller.error != null) return;
    final selected = <String>{};
    final linked = widget.controller.sources.map((s) => s['id']).toSet();
    final result = await showDialog<Set<String>>(
      animationStyle: GazeMotion.style(context),
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Choose Spotify playlists'),
          content: SizedBox(
            width: 540,
            height: 400,
            child: widget.controller.playlists.isEmpty
                ? const Center(
                    child: Text('No accessible Spotify playlists were found.'),
                  )
                : ListView(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 16),
                        child: Text(
                          'gaze keeps a private copy on your server. Choose Sync now whenever you want to bring over changes from Spotify.',
                        ),
                      ),
                      for (final p in widget.controller.playlists)
                        CheckboxListTile(
                          value:
                              linked.contains(p['id']) ||
                              selected.contains(p['id']),
                          onChanged: linked.contains(p['id'])
                              ? null
                              : (value) => update(() {
                                  if (value == true) {
                                    selected.add(p['id'] as String);
                                  } else {
                                    selected.remove(p['id']);
                                  }
                                }),
                          title: Text(
                            p['name'] as String? ?? 'Spotify playlist',
                          ),
                          subtitle: Text(
                            linked.contains(p['id'])
                                ? 'Already linked'
                                : '${p['count'] ?? '—'} songs · ${p['owner'] ?? ''}',
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, selected),
              child: Text(
                'Import ${selected.length == 1 ? 'playlist' : 'playlists'}',
              ),
            ),
          ],
        ),
      ),
    );
    if (result != null) await widget.controller.selectPlaylists(result);
  }

  Future<void> _manualMatch(Map<String, dynamic> job) async {
    final result = await showDialog<Map<String, dynamic>>(
      animationStyle: GazeMotion.style(context),
      context: context,
      builder: (context) => _ManualMatchDialog(job: job),
    );
    if (result != null)
      await widget.controller.change('/v1/jobs/${job['id']}/match', result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        onPressed: widget.onClose,
        tooltip: 'Back to gaze',
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      title: const Text('Connect'),
    ),
    body: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller, online = c.connection.state.isConnected;
        final jobs = c.jobs;
        final attention = jobs
            .where((j) => ['needsMatch', 'failed'].contains(j['status']))
            .length;
        final ready = c.savedImportCount;
        final working = jobs.length - attention;
        final shown = _needsOnly
            ? jobs
                  .where((j) => ['needsMatch', 'failed'].contains(j['status']))
                  .toList()
            : jobs;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Bring your music together.',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your library, Spotify playlists, and Synopti—connected through your server.',
                    style: TextStyle(color: GazeColors.textSecondary),
                  ),
                  const SizedBox(height: 28),
                  if (!online) ...[
                    JellyfinConnectionScreen(
                      controller: c.connection,
                      onClose: widget.onClose,
                      embedded: true,
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Connect to your library to manage Spotify and imports. Saved music and playlists stay on your server.',
                    ),
                  ] else ...[
                    _Card(
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle_rounded,
                            color: Color(0xFF79C99E),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Music library',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                Text(
                                  '${c.connection.state.session!.userName} · ${c.connection.state.serverInfo?.name ?? 'Jellyfin'}',
                                  style: const TextStyle(
                                    color: GazeColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: c.connection.disconnect,
                            child: const Text('Disconnect'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (c.snapshot == null)
                      _Card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Connect your gaze service',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'The service saves imports and keeps playlists up to date, even when this app is closed.',
                            ),
                            const SizedBox(height: 20),
                            TextField(
                              controller: _address,
                              enabled: !c.busy,
                              decoration: const InputDecoration(
                                labelText: 'gaze service address',
                                border: OutlineInputBorder(),
                              ),
                              onSubmitted: c.busy ? null : c.connect,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: c.busy
                                  ? null
                                  : () => c.connect(_address.text),
                              icon: c.busy
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.link_rounded),
                              label: Text(
                                c.busy ? 'Connecting…' : 'Connect service',
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      if (c.artwork.isNotEmpty) ...[
                        _ArtworkCard(controller: c),
                        const SizedBox(height: 20),
                      ],
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.maxWidth >= 800
                              ? (constraints.maxWidth - 20) / 2
                              : constraints.maxWidth;
                          return Wrap(
                            spacing: 20,
                            runSpacing: 20,
                            children: [
                              SizedBox(
                                width: width,
                                child: _Card(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Icon(
                                        Icons.library_music_rounded,
                                        color: Color(0xFF79C99E),
                                        size: 30,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'Spotify',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        c.spotify['connected'] == true
                                            ? 'Connected as ${c.spotify['name'] ?? 'your Spotify account'}'
                                            : 'Choose the playlists you want in your gaze library.',
                                      ),
                                      const SizedBox(height: 20),
                                      if (c.spotify['connected'] == true)
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            FilledButton.icon(
                                              onPressed: c.busy
                                                  ? null
                                                  : _choosePlaylists,
                                              icon: const Icon(
                                                Icons.playlist_add_rounded,
                                              ),
                                              label: const Text(
                                                'Choose playlists',
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: c.busy
                                                  ? null
                                                  : () => c.change(
                                                      '/v1/spotify/disconnect',
                                                      {},
                                                    ),
                                              child: const Text(
                                                'Disconnect Spotify',
                                              ),
                                            ),
                                          ],
                                        )
                                      else ...[
                                        FilledButton.icon(
                                          onPressed: c.busy || c.signingIn
                                              ? null
                                              : c.signIn,
                                          icon: const Icon(
                                            Icons.open_in_new_rounded,
                                          ),
                                          label: Text(
                                            c.signingIn
                                                ? 'Finish sign-in in your browser…'
                                                : 'Sign in with Spotify',
                                          ),
                                        ),
                                        if (c.spotify['canReuse'] == true)
                                          TextButton(
                                            onPressed: c.busy
                                                ? null
                                                : () => c.change(
                                                    '/v1/spotify/reuse',
                                                    {},
                                                  ),
                                            child: const Text(
                                              'Use Synopti’s connected Spotify account',
                                            ),
                                          ),
                                        const SizedBox(height: 8),
                                        ExpansionTile(
                                          tilePadding: EdgeInsets.zero,
                                          title: const Text(
                                            'Spotify app setup',
                                            style: TextStyle(fontSize: 13),
                                          ),
                                          children: [
                                            const Text(
                                              'For a new sign-in, register this callback in your Spotify app settings. Synopti’s existing connection can be used without this setup.',
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Expanded(
                                                  child: SelectableText(
                                                    'http://127.0.0.1/spotify/callback',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip:
                                                      'Copy Spotify callback',
                                                  onPressed: () =>
                                                      Clipboard.setData(
                                                        const ClipboardData(
                                                          text:
                                                              'http://127.0.0.1/spotify/callback',
                                                        ),
                                                      ),
                                                  icon: const Icon(
                                                    Icons.copy_rounded,
                                                    size: 18,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: width,
                                child: _Card(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Icon(
                                        Icons.graphic_eq_rounded,
                                        color: Color(0xFFBCAAE8),
                                        size: 30,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'Synopti',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Save songs played by the bot when their title and artist are missing from your library.',
                                      ),
                                      const SizedBox(height: 16),
                                      SwitchListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('Sync played songs'),
                                        subtitle: Text(
                                          c.synopti['enabled'] == true
                                              ? 'Listening for played songs on your server'
                                              : 'Downloads use the best available source audio',
                                        ),
                                        value: c.synopti['enabled'] == true,
                                        onChanged: c.busy
                                            ? null
                                            : (value) => c.change(
                                                '/v1/synopti',
                                                {'enabled': value},
                                              ),
                                      ),
                                      if (c.synopti['error'] is String)
                                        Text(
                                          c.synopti['error'] as String,
                                          style: const TextStyle(
                                            color: Color(0xFFF0C880),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      if (c.sources.isNotEmpty) ...[
                        Text(
                          'Linked playlists',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        for (final source in c.sources)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _Card(
                              child: Row(
                                children: [
                                  const Icon(Icons.sync_rounded),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          source['name'] as String? ??
                                              'Spotify playlist',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${source['savedCount'] ?? 0} saved · ${source['pendingCount'] ?? (source['jobIds'] as List? ?? []).length} pending · Manual sync',
                                          style: const TextStyle(
                                            color: GazeColors.textSecondary,
                                          ),
                                        ),
                                        if ((source['error'] ??
                                                source['mirrorError'])
                                            is String)
                                          Text(
                                            (source['error'] ??
                                                    source['mirrorError'])
                                                as String,
                                            style: const TextStyle(
                                              color: Color(0xFFF0C880),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Sync playlist now',
                                    onPressed: c.busy
                                        ? null
                                        : () => c.change(
                                            '/v1/sources/${source['id']}/sync',
                                            {},
                                          ),
                                    icon: const Icon(Icons.refresh_rounded),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Sync queue',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Refresh imports',
                            onPressed: c.refresh,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$ready saved · $working in progress · $attention need attention',
                        style: const TextStyle(color: GazeColors.textSecondary),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: Text('Needs attention ($attention)'),
                            selected: _needsOnly,
                            onSelected: (_) =>
                                setState(() => _needsOnly = true),
                          ),
                          ChoiceChip(
                            label: Text('In queue (${jobs.length})'),
                            selected: !_needsOnly,
                            onSelected: (_) =>
                                setState(() => _needsOnly = false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _Card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.high_quality_rounded,
                                  size: 20,
                                  color: Color(0xFF79C99E),
                                ),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Best available audio · No re-encoding',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'If the highest quality is unavailable, gaze tries the next available format. The downloaded audio is preserved and verified after tagging.',
                              style: TextStyle(
                                color: GazeColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 20),
                            if (shown.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 20,
                                ),
                                child: Text(
                                  jobs.isEmpty
                                      ? 'Your sync queue is clear.'
                                      : _needsOnly
                                      ? 'No imports need your attention.'
                                      : 'Your sync queue is clear.',
                                ),
                              ),
                            for (final job in shown)
                              _ImportRow(
                                job: job,
                                busy: c.busy,
                                onMatch: () => _manualMatch(job),
                                onRetry: () =>
                                    c.change('/v1/jobs/${job['id']}/retry', {}),
                              ),
                          ],
                        ),
                      ),
                    ],
                    if (c.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: SelectableText(
                          c.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _ArtworkCard extends StatelessWidget {
  const _ArtworkCard({required this.controller});
  final ConnectController controller;
  @override
  Widget build(BuildContext context) {
    final data = controller.artwork;
    final searching =
        ['queued', 'scanning', 'searching'].contains(data['status']) ||
        (data['queued'] as num? ?? 0) > 0;
    final unresolved = (data['entries'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .where((e) => ['noMatch', 'failed'].contains(e['status']))
        .toList();
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.image_search_rounded, color: GazeColors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Album artwork',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Missing covers are filled after import. Search your existing library too—covers you already have stay in place.',
            style: TextStyle(color: GazeColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed:
                    controller.busy || searching || data['canManage'] != true
                    ? null
                    : () => controller.change('/v1/artwork/search', {}),
                icon: searching
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search_rounded),
                label: Text(
                  searching ? 'Finding covers…' : 'Find missing artwork',
                ),
              ),
              if (data['status'] != 'idle' || (data['found'] as num? ?? 0) > 0)
                Text(
                  '${data['found'] ?? 0} covers found · ${(data['missing'] as num? ?? 0) + (data['failed'] as num? ?? 0)} still missing',
                  style: const TextStyle(color: GazeColors.textSecondary),
                ),
            ],
          ),
          if (data['canManage'] != true)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'A Jellyfin administrator can save covers for this library.',
              ),
            ),
          if (data['error'] is String)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                data['error'] as String,
                style: const TextStyle(color: Color(0xFFF0C880)),
              ),
            ),
          if (unresolved.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Covers still missing (${unresolved.length})'),
              children: [
                for (final entry in unresolved)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.album_outlined),
                    title: Text(entry['album'] as String? ?? 'Album'),
                    subtitle: Text(
                      '${(entry['artists'] as List? ?? []).join(', ')}\n${entry['error'] ?? 'No cover found.'}',
                    ),
                    isThreeLine: true,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: GazeColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: GazeColors.outline),
    ),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: double.infinity,
      child: Padding(padding: const EdgeInsets.all(24), child: child),
    ),
  );
}

class _ImportRow extends StatelessWidget {
  const _ImportRow({
    required this.job,
    required this.busy,
    required this.onMatch,
    required this.onRetry,
  });
  final Map<String, dynamic> job;
  final bool busy;
  final VoidCallback onMatch;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final status = job['status'] as String? ?? 'queued',
        attention = ['needsMatch', 'failed'].contains(status),
        quality = job['quality'] as Map<String, dynamic>?;
    final hasSynoptiSource =
        job['kind'] == 'Synopti' &&
        job['youtubeUrl'] is String &&
        (job['youtubeUrl'] as String).isNotEmpty;
    final label = switch (status) {
      'ready' =>
        job['reused'] == true
            ? 'Already in your library'
            : 'Saved at original quality',
      'needsMatch' =>
        hasSynoptiSource
            ? 'YouTube source already available'
            : 'Needs a YouTube match',
      'failed' => 'Import failed',
      'matching' => 'Finding the right recording…',
      'downloading' => 'Saving best available audio…',
      'scanning' => 'Audio saved · Waiting for Jellyfin to index it…',
      _ => 'Queued for import',
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: GazeColors.outline)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 12,
          children: [
            SizedBox(
              width: constraints.maxWidth >= 650
                  ? constraints.maxWidth - 245
                  : constraints.maxWidth,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    status == 'ready'
                        ? Icons.check_circle_outline_rounded
                        : attention
                        ? Icons.error_outline_rounded
                        : Icons.hourglass_top_rounded,
                    size: 20,
                    color: attention
                        ? const Color(0xFFF0C880)
                        : const Color(0xFF79C99E),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job['title'] as String? ?? 'Unknown song',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          (job['artists'] as List? ?? []).join(', '),
                          style: const TextStyle(
                            color: GazeColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        GazeSwap(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            label,
                            key: ValueKey(label),
                            style: TextStyle(
                              fontSize: 12,
                              color: attention
                                  ? const Color(0xFFF0C880)
                                  : GazeColors.textSecondary,
                            ),
                          ),
                        ),
                        if (job['error'] is String && attention)
                          Text(
                            hasSynoptiSource && status == 'needsMatch'
                                ? 'Use the recording Synopti already played. Missing artist details do not require another link.'
                                : job['error'] as String,
                            style: const TextStyle(
                              fontSize: 12,
                              color: GazeColors.textSecondary,
                            ),
                          ),
                        if (quality != null)
                          Text(
                            '${(quality['codec'] as String? ?? '').toUpperCase()} · ${quality['bitrate'] == null ? 'bitrate unavailable' : '${((quality['bitrate'] as num) / 1000).round()} kbps'} · ${quality['sampleRate'] == null ? '' : '${(quality['sampleRate'] as num) / 1000} kHz'} · source preserved',
                            style: const TextStyle(
                              fontSize: 12,
                              color: GazeColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (attention)
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : hasSynoptiSource && status == 'needsMatch'
                        ? onRetry
                        : onMatch,
                    icon: Icon(
                      hasSynoptiSource && status == 'needsMatch'
                          ? Icons.download_rounded
                          : Icons.link_rounded,
                      size: 16,
                    ),
                    label: Text(
                      hasSynoptiSource && status == 'needsMatch'
                          ? 'Import played version'
                          : hasSynoptiSource
                          ? 'Change source'
                          : 'Paste YouTube link',
                    ),
                  ),
                  if (status == 'failed')
                    IconButton(
                      tooltip: 'Retry import',
                      onPressed: busy ? null : onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ManualMatchDialog extends StatefulWidget {
  const _ManualMatchDialog({required this.job});
  final Map<String, dynamic> job;
  @override
  State<_ManualMatchDialog> createState() => _ManualMatchDialogState();
}

class _ManualMatchDialogState extends State<_ManualMatchDialog> {
  final _form = GlobalKey<FormState>();
  late final _link = TextEditingController(
    text: widget.job['unidentified'] == true
        ? widget.job['youtubeUrl'] as String? ?? ''
        : '',
  );
  late final _title = TextEditingController(
    text: widget.job['kind'] == 'Synopti'
        ? widget.job['title'] as String? ?? ''
        : '',
  );
  final _artist = TextEditingController();
  @override
  void dispose() {
    _link.dispose();
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  String? _validateLink(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort)
      return 'Paste a direct HTTPS YouTube video link.';
    final id = uri.host == 'youtu.be'
        ? uri.path.substring(1)
        : [
                'www.youtube.com',
                'youtube.com',
                'music.youtube.com',
              ].contains(uri.host) &&
              uri.path == '/watch'
        ? uri.queryParameters['v']
        : ['www.youtube.com', 'youtube.com'].contains(uri.host) &&
              RegExp(r'^/(shorts|embed)/').hasMatch(uri.path)
        ? uri.path.split('/').last
        : null;
    return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id ?? '')
        ? null
        : 'Use a link to one YouTube video.';
  }

  void _submit() {
    if (_form.currentState!.validate())
      Navigator.pop(context, <String, dynamic>{
        'url': _link.text.trim(),
        if (widget.job['unidentified'] == true) 'title': _title.text.trim(),
        if (widget.job['unidentified'] == true) 'artist': _artist.text.trim(),
      });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Match ${widget.job['title']}'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text((widget.job['artists'] as List? ?? []).join(', ')),
              if (widget.job['unidentified'] == true) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _title,
                  decoration: const InputDecoration(
                    labelText: 'Song title',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? null
                      : 'Enter the song title.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _artist,
                  decoration: const InputDecoration(
                    labelText: 'Artist',
                    hintText: 'Separate multiple artists with ;',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? null
                      : 'Enter the artist.',
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                'Choose the recording and edit you want. gaze will save the best available audio from that video without re-encoding.',
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _link,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'YouTube video link',
                  hintText: 'https://www.youtube.com/watch?v=…',
                  border: OutlineInputBorder(),
                ),
                validator: _validateLink,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Use this version')),
    ],
  );
}
