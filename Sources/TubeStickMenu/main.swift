import AppKit
import TubeStickKit

let app = NSApplication.shared

let delegate = MenuController()
app.delegate = delegate
app.run()
