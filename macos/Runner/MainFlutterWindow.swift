import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    self.delegate = self
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let fileOpenChannel = FlutterMethodChannel(
      name: "tech.rslive.superracktools/files",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    (NSApp.delegate as? AppDelegate)?.registerFileOpenChannel(fileOpenChannel)

    super.awakeFromNib()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Closing the last window normally terminates macOS apps directly. Route
    // the close button through NSApplication so Flutter can ask Dart to confirm
    // any pending edits before the process exits.
    NSApp.terminate(nil)
    return false
  }
}
