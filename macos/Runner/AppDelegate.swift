import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var pendingPartyLink: String?
  var partyChannel: FlutterMethodChannel?
  func configurePartyLinks(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "gaze/party_links", binaryMessenger: controller.engine.binaryMessenger)
    partyChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "initialLink" { result(self?.pendingPartyLink); self?.pendingPartyLink = nil }
      else { result(FlutterMethodNotImplemented) }
    }
  }
  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let link = urls.first?.absoluteString, link.hasPrefix("gaze://party/"), link.count <= 2048 else { return }
    if let channel = partyChannel { channel.invokeMethod("openLink", arguments: link) }
    else { pendingPartyLink = link }
    application.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
