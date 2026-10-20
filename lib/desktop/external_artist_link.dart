import 'dart:io';
import 'package:flutter/material.dart';

/// External source links are fixed to the metadata providers used by gaze.
class ExternalArtistLink extends StatelessWidget {
  const ExternalArtistLink({
    required this.label,
    required this.url,
    this.credit,
    super.key,
  });
  final String label, url;
  final String? credit;
  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        !const {
          'musicbrainz.org',
          'en.wikipedia.org',
          'commons.wikimedia.org',
          'listenbrainz.org',
        }.contains(uri.host))
      return;
    try {
      final executable = Platform.isLinux
          ? 'xdg-open'
          : Platform.isMacOS
          ? 'open'
          : Platform.isWindows
          ? 'rundll32'
          : null;
      if (executable == null) throw const ProcessException('browser', []);
      final result = await Process.run(executable, [
        if (Platform.isWindows) 'url.dll,FileProtocolHandler',
        url,
      ]);
      if (result.exitCode != 0) throw const ProcessException('browser', []);
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The source could not be opened in your browser.'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(
      textStyle: Theme.of(context).textTheme.labelSmall,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    onPressed: () => _open(context),
    child: Text(credit == null ? label : '$label: $credit'),
  );
}
