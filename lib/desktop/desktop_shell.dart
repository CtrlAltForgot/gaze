import 'package:flutter/material.dart';

import '../design/gaze_theme.dart';

class DesktopShell extends StatelessWidget {
  const DesktopShell({
    required this.onOpenJellyfinConnection,
    required this.onOpenPlaybackTest,
    super.key,
  });

  final VoidCallback onOpenJellyfinConnection;
  final VoidCallback onOpenPlaybackTest;

  static const _albums = [
    _SampleAlbum('Northern Lines', 'Aster Vale', [
      Color(0xFF725B92),
      Color(0xFF273353),
    ]),
    _SampleAlbum('Still Current', 'Low Water', [
      Color(0xFFB96854),
      Color(0xFF4E2832),
    ]),
    _SampleAlbum('Glass Hours', 'Mira North', [
      Color(0xFF4B8F91),
      Color(0xFF203D4B),
    ]),
    _SampleAlbum('Soft Geometry', 'Field Study', [
      Color(0xFFC29A55),
      Color(0xFF54432E),
    ]),
    _SampleAlbum('After Image', 'Quiet Assembly', [
      Color(0xFF5E789B),
      Color(0xFF292C50),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compactNavigation = constraints.maxWidth < 920;
          return Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Navigation(
                      compact: compactNavigation,
                      onOpenJellyfinConnection: onOpenJellyfinConnection,
                      onOpenPlaybackTest: onOpenPlaybackTest,
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    const Expanded(child: _HomeContent()),
                  ],
                ),
              ),
              const _PlayerPlaceholder(),
            ],
          );
        },
      ),
    );
  }
}

class _Navigation extends StatelessWidget {
  const _Navigation({
    required this.compact,
    required this.onOpenJellyfinConnection,
    required this.onOpenPlaybackTest,
  });

  final bool compact;
  final VoidCallback onOpenJellyfinConnection;
  final VoidCallback onOpenPlaybackTest;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: GazeColors.navigation,
      child: SizedBox(
        width: compact ? 80 : 224,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? GazeSpacing.small : GazeSpacing.medium,
            vertical: GazeSpacing.large,
          ),
          child: Column(
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: GazeSpacing.small,
                ),
                child: Text(
                  compact ? 'g' : 'gaze',
                  textAlign: compact ? TextAlign.center : TextAlign.left,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: GazeSpacing.xLarge),
              _NavigationItem(
                icon: Icons.home_rounded,
                label: 'Home',
                compact: compact,
                selected: true,
              ),
              _NavigationItem(
                icon: Icons.album_outlined,
                label: 'Albums',
                compact: compact,
              ),
              _NavigationItem(
                icon: Icons.people_outline_rounded,
                label: 'Artists',
                compact: compact,
              ),
              _NavigationItem(
                icon: Icons.music_note_rounded,
                label: 'Songs',
                compact: compact,
              ),
              _NavigationItem(
                icon: Icons.queue_music_rounded,
                label: 'Playlists',
                compact: compact,
              ),
              const Spacer(),
              Tooltip(
                message: 'Connect to Jellyfin',
                child: TextButton.icon(
                  onPressed: onOpenJellyfinConnection,
                  icon: const Icon(Icons.cloud_outlined),
                  label: compact
                      ? const SizedBox.shrink()
                      : const Text('Connect Jellyfin'),
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: GazeColors.textSecondary,
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ),
              Tooltip(
                message: 'Open the playback technical test',
                child: TextButton.icon(
                  onPressed: onOpenPlaybackTest,
                  icon: const Icon(Icons.science_outlined),
                  label: compact
                      ? const SizedBox.shrink()
                      : const Text('Playback test'),
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: GazeColors.textSecondary,
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.compact,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final bool compact;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? GazeColors.textPrimary
        : GazeColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: GazeSpacing.xSmall),
      child: Semantics(
        selected: selected,
        button: true,
        label: label,
        child: Material(
          color: selected ? GazeColors.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(GazeRadii.control),
          child: InkWell(
            onTap: () {},
            borderRadius: BorderRadius.circular(GazeRadii.control),
            child: SizedBox(
              height: 48,
              child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  if (!compact) const SizedBox(width: GazeSpacing.medium),
                  Icon(icon, color: foreground, size: 21),
                  if (!compact) ...[
                    const SizedBox(width: GazeSpacing.medium),
                    Text(
                      label,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent();

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GazeSpacing.xLarge,
            GazeSpacing.large,
            GazeSpacing.xLarge,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your music, brought forward.',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: GazeSpacing.small),
                      const Text(
                        'A calm place for the albums you chose to keep.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: GazeSpacing.large),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: const TextField(
                    decoration: InputDecoration(
                      hintText: 'Search your library',
                      prefixIcon: Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: GazeColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(GazeRadii.control),
                        ),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GazeSpacing.xLarge,
            GazeSpacing.xxLarge,
            GazeSpacing.xLarge,
            GazeSpacing.medium,
          ),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Recently added',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            GazeSpacing.xLarge,
            0,
            GazeSpacing.xLarge,
            GazeSpacing.xLarge,
          ),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.crossAxisExtent;
              final columns = width >= 1160
                  ? 5
                  : width >= 880
                  ? 4
                  : width >= 600
                  ? 3
                  : 2;
              return SliverGrid.builder(
                itemCount: DesktopShell._albums.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: GazeSpacing.large,
                  mainAxisSpacing: GazeSpacing.xLarge,
                  childAspectRatio: 0.78,
                ),
                itemBuilder: (context, index) =>
                    _AlbumCard(album: DesktopShell._albums[index]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album});

  final _SampleAlbum album;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${album.title} by ${album.artist}',
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(GazeRadii.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(GazeRadii.card),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: album.colors,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x55000000),
                        blurRadius: 22,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      color: Color(0x66FFFFFF),
                      size: 52,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: GazeSpacing.medium),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: GazeSpacing.xSmall),
            Text(album.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _PlayerPlaceholder extends StatelessWidget {
  const _PlayerPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 92,
      padding: const EdgeInsets.symmetric(horizontal: GazeSpacing.large),
      decoration: const BoxDecoration(
        color: GazeColors.navigation,
        border: Border(top: BorderSide(color: GazeColors.outline)),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: GazeColors.surfaceRaised,
              borderRadius: BorderRadius.circular(GazeRadii.control),
            ),
            child: const Icon(
              Icons.music_note_rounded,
              color: GazeColors.textSecondary,
            ),
          ),
          const SizedBox(width: GazeSpacing.medium),
          const Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Nothing playing',
                  style: TextStyle(
                    color: GazeColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: GazeSpacing.xSmall),
                Text('Choose something when your library is connected.'),
              ],
            ),
          ),
          const _DisabledPlayerControl(
            icon: Icons.skip_previous_rounded,
            label: 'Previous',
          ),
          const _DisabledPlayerControl(
            icon: Icons.play_arrow_rounded,
            label: 'Play',
            prominent: true,
          ),
          const _DisabledPlayerControl(
            icon: Icons.skip_next_rounded,
            label: 'Next',
          ),
        ],
      ),
    );
  }
}

class _DisabledPlayerControl extends StatelessWidget {
  const _DisabledPlayerControl({
    required this.icon,
    required this.label,
    this.prominent = false,
  });

  final IconData icon;
  final String label;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: null,
      tooltip: label,
      iconSize: prominent ? 30 : 24,
      icon: Icon(icon),
    );
  }
}

class _SampleAlbum {
  const _SampleAlbum(this.title, this.artist, this.colors);

  final String title;
  final String artist;
  final List<Color> colors;
}
