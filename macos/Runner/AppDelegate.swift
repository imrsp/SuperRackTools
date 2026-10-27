import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var fileOpenChannel: FlutterMethodChannel?
  private var pendingOpenFiles: [String] = []
  private var dartReadyForFiles = false

  func registerFileOpenChannel(_ channel: FlutterMethodChannel) {
    fileOpenChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "drainOpenFiles" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else {
        result([])
        return
      }
      self.dartReadyForFiles = true
      let paths = self.pendingOpenFiles
      self.pendingOpenFiles.removeAll()
      result(paths)
    }
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let paths = filenames.filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "sprk" }
    if dartReadyForFiles {
      paths.forEach { fileOpenChannel?.invokeMethod("openFile", arguments: $0) }
    } else {
      pendingOpenFiles.append(contentsOf: paths)
    }
    sender.reply(toOpenOrPrint: .success)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
