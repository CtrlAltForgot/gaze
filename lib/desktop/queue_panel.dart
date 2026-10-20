import 'dart:typed_data';
import '../party/party_controller.dart';
import 'party_dialog.dart';
import 'party_song_search.dart';
import 'artist_links.dart';
import '../design/gaze_motion.dart';
import 'marquee_text.dart';
import 'package:flutter/material.dart';
import '../design/gaze_theme.dart';
import '../playback/playback_queue_controller.dart';
import '../jellyfin/jellyfin_connection_controller.dart';
import 'song_row.dart';
import 'playlist_dialogs.dart';
import '../playback/playback_controller.dart';

class QueuePanel extends StatelessWidget {
  const QueuePanel({
    required this.controller,
    required this.connectionController,
    required this.online,
    required this.onClose,
    this.partyController,
    super.key,
  });
  final PlaybackQueueController controller;
  final JellyfinConnectionController connectionController;
  final bool online;
  final VoidCallback onClose;
  final PartyController? partyController;
  Future<void> _play(BuildContext context, int index) async {
    try {
      await controller.playAt(index);
    } on Exception catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Widget _cover(RemotePlaybackSource source) =>
      partyController?.following == true
      ? FutureBuilder<Uint8List?>(
          future: partyController!.artworkFor(source),
          initialData: source.artworkBytes,
          builder: (context, snapshot) => ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: snapshot.data == null
                ? const SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(Icons.music_note_rounded),
                  )
                : Image.memory(
                    snapshot.data!,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
          ),
        )
      : LibraryArtwork(
          connectionController: connectionController,
          itemId: source.artworkId,
          imageTag: source.artworkTag,
          bytes: source.artworkBytes,
          dimension: 44,
        );
  @override
  Widget build(BuildContext context) => Material(
    color: GazeColors.navigation.withValues(alpha: .68),
    child: StreamBuilder<PlaybackQueueState>(
      stream: controller.states,
      initialData: controller.state,
      builder: (context, snapshot) {
        final queue = snapshot.data ?? controller.state;
        final current =
            queue.currentIndex >= 0 && queue.currentIndex < queue.items.length
            ? queue.items[queue.currentIndex]
            : null;
        final start = queue.currentIndex + 1;
        final count = current == null ? 0 : queue.items.length - start;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Queue',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  if (partyController != null)
                    ListenableBuilder(
                      listenable: partyController!,
                      builder: (context, _) => IconButton(
                        tooltip: 'Party Session',
                        color: partyController!.active
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        onPressed: () =>
                            showPartyDialog(context, partyController!),
                        icon: Icon(
                          partyController!.active
                              ? Icons.group_rounded
                              : Icons.ios_share_rounded,
                          size: 21,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Save queue as playlist',
                    onPressed:
                        !online ||
                            current == null ||
                            queue.items
                                .skip(queue.currentIndex)
                                .any((source) => source.itemId == null)
                        ? null
                        : () async {
                            final playlist = await showPlaylistNameDialog(
                              context,
                              connectionController,
                              itemIds: queue.items
                                  .skip(queue.currentIndex)
                                  .map((source) => source.itemId!)
                                  .toList(growable: false),
                            );
                            if (context.mounted && playlist != null)
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Saved ${playlist.title} to your account',
                                  ),
                                ),
                              );
                          },
                    icon: const Icon(Icons.playlist_add_rounded),
                  ),
                  IconButton(
                    tooltip: 'Close queue',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (partyController != null)
              ListenableBuilder(
                listenable: partyController!,
                builder: (context, _) => partyController!.active
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: TextButton.icon(
                          onPressed: () =>
                              showPartyDialog(context, partyController!),
                          icon: const Icon(
                            Icons.people_outline_rounded,
                            size: 18,
                          ),
                          label: Text(
                            partyController!.hosting
                                ? 'Hosting · ${partyController!.listeners.length} listening'
                                : 'Listening with ${partyController!.hostName}',
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            if (partyController != null)
              ListenableBuilder(
                listenable: partyController!,
                builder: (context, _) => partyController!.active
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              showPartySongSearch(context, partyController!),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add songs'),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            if (current == null)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Your queue is empty.\nPlay some music or add a song to the queue.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(
                  'Now playing',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              ListTile(
                leading: _cover(current),
                title: MarqueeText(current.title, hoverOnly: true),
                subtitle: ArtistLinks(current.artist, hoverOnly: true),
                trailing: const Icon(Icons.equalizer_rounded),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.only(left: 20, right: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Up next · $count',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: count == 0 ? null : controller.clearUpcoming,
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ),
              if (!online && !controller.followingParty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Text('Reconnect to play queued songs.'),
                ),
              Expanded(
                child: count == 0
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Nothing queued after this song.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: count,
                        onReorderItem: (oldIndex, newIndex) {
                          controller.moveUpcoming(
                            start + oldIndex,
                            start + newIndex,
                          );
                        },
                        itemBuilder: (context, index) {
                          final source = queue.items[start + index];
                          return ListTile(
                            key: ValueKey('$index:${identityHashCode(source)}'),
                            contentPadding: const EdgeInsets.only(
                              left: 16,
                              right: 4,
                            ),
                            leading: _cover(source),
                            title: MarqueeText(source.title, hoverOnly: true),
                            subtitle: ArtistLinks(
                              source.artist,
                              hoverOnly: true,
                            ),
                            onTap: !online && !controller.followingParty
                                ? null
                                : () => _play(context, start + index),
                            trailing: SizedBox(
                              width: 88,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PopupMenuButton<String>(
                                    popUpAnimationStyle: GazeMotion.style(
                                      context,
                                    ),
                                    tooltip:
                                        'Queue options for ${source.title}',
                                    onSelected: (action) {
                                      if (action == 'remove')
                                        controller.removeAt(start + index);
                                      if (action == 'up')
                                        controller.moveUpcoming(
                                          start + index,
                                          start + index - 1,
                                        );
                                      if (action == 'down')
                                        controller.moveUpcoming(
                                          start + index,
                                          start + index + 1,
                                        );
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        value: 'up',
                                        enabled: index > 0,
                                        child: const Text('Move up'),
                                      ),
                                      PopupMenuItem(
                                        value: 'down',
                                        enabled: index + 1 < count,
                                        child: const Text('Move down'),
                                      ),
                                      const PopupMenuItem(
                                        value: 'remove',
                                        child: Text('Remove from queue'),
                                      ),
                                    ],
                                  ),
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: const SizedBox(
                                      width: 32,
                                      height: 48,
                                      child: Tooltip(
                                        message: 'Drag to reorder',
                                        child: Icon(Icons.drag_handle_rounded),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        );
      },
    ),
  );
}
