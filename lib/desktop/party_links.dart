import 'package:flutter/services.dart';

/// Native runners forward both initial and already-running app invitations.
class PartyLinks {
  static const _channel = MethodChannel('gaze/party_links');
  Future<void> start(void Function(String) onLink) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openLink' && call.arguments is String)
        onLink(call.arguments as String);
    });
    try {
      final initial = await _channel.invokeMethod<String>('initialLink');
      if (initial != null) onLink(initial);
    } on MissingPluginException {
      /* Paste-link flow works on every desktop. */
    }
  }

  void dispose() => _channel.setMethodCallHandler(null);
}
