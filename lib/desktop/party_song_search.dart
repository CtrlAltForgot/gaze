import 'dart:async';
import 'package:flutter/material.dart';
import '../design/gaze_motion.dart';
import '../party/party_controller.dart';
import 'marquee_text.dart';

Future<void> showPartySongSearch(BuildContext context, PartyController party) =>
    showDialog<void>(
      context: context,
      animationStyle: GazeMotion.style(context),
      builder: (_) => _Search(party: party),
    );

class _Search extends StatefulWidget {
  const _Search({required this.party});
  final PartyController party;
  @override
  State<_Search> createState() => _SearchState();
}

class _SearchState extends State<_Search> {
  Timer? _debounce;
  int _request = 0;
  bool _loading = false;
  String? _error, _adding;
  final _added = <String>{};
  List<Map<String, dynamic>> _songs = [];
  void _search(String query) {
    _debounce?.cancel();
    final request = ++_request;
    if (query.trim().length < 2) {
      setState(() {
        _songs = [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final songs = await widget.party.search(query.trim());
        if (mounted && request == _request)
          setState(() {
            _songs = songs;
            _loading = false;
          });
      } catch (e) {
        if (mounted && request == _request)
          setState(() {
            _error = e.toString();
            _loading = false;
          });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('Add to the party')),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
    content: SizedBox(
      width: 520,
      height: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            autofocus: true,
            onChanged: _search,
            decoration: const InputDecoration(
              hintText: 'Search songs and artists',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'From ${widget.party.hostName}’s library',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Expanded(
            child: _songs.isEmpty
                ? Center(
                    child: Text(
                      _loading
                          ? 'Finding music…'
                          : 'Search for a song to share.',
                    ),
                  )
                : ListView.builder(
                    itemCount: _songs.length,
                    itemBuilder: (context, index) {
                      final song = _songs[index], id = song['id'] as String;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: MarqueeText(song['title'], hoverOnly: true),
                        subtitle: MarqueeText(song['artist'], hoverOnly: true),
                        trailing: IconButton(
                          tooltip: _added.contains(id)
                              ? 'Added to queue'
                              : 'Add to queue',
                          icon: _adding == id
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _added.contains(id)
                                      ? Icons.check_rounded
                                      : Icons.add_rounded,
                                ),
                          onPressed: _adding != null
                              ? null
                              : () async {
                                  setState(() => _adding = id);
                                  await widget.party.command('add', {
                                    'itemId': id,
                                  });
                                  if (mounted)
                                    setState(() {
                                      _adding = null;
                                      _error = widget.party.error;
                                      if (_error == null) _added.add(id);
                                    });
                                },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
