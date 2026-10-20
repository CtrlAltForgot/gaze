import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../party/party_controller.dart';
import '../playback/playback_controller.dart';
import 'marquee_text.dart';
import 'party_song_search.dart';

class PartyListeningView extends StatelessWidget {
  const PartyListeningView({required this.party, super.key});
  final PartyController party;
  @override
  Widget build(BuildContext context) => StreamBuilder<PlaybackSnapshot>(
    stream: party.playback.states,
    initialData: party.playback.state,
    builder: (context, snapshot) {
      final song = snapshot.data ?? party.playback.state;
      return LayoutBuilder(
        builder: (context, bounds) {
          final size = math.min(
            280.0,
            math.max(
              100.0,
              math.min(bounds.maxWidth - 64, bounds.maxHeight * .43),
            ),
          );
          return SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PARTY SESSION',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(letterSpacing: 2),
                ),
                const SizedBox(height: 6),
                Text(
                  'Listening with ${party.hostName}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 28),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: song.artworkBytes == null
                        ? SizedBox(
                            width: size,
                            height: size,
                            child: const Icon(
                              Icons.music_note_rounded,
                              size: 64,
                            ),
                          )
                        : Image.memory(
                            song.artworkBytes!,
                            width: size,
                            height: size,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                  ),
                ),
                const SizedBox(height: 24),
                MarqueeText(
                  song.title ?? 'Joining the music…',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                MarqueeText(
                  song.artist ?? '',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () => showPartySongSearch(context, party),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add a song'),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
