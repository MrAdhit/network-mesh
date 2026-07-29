import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Filament is a dense instrument panel: below 900x600 the rail and the 880pt
    // content column stop coexisting, so the window refuses to go smaller.
    self.contentMinSize = NSSize(width: 900, height: 600)
    self.setContentSize(NSSize(width: 1100, height: 720))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
