import AppKit
import NotchideApp

// Thin executable entry point.
//
// Everything real lives in the `NotchideApp` library so it compiles and is
// verifiable independently of whether a bundle-less SwiftUI executable links
// cleanly under Command Line Tools. Here we only:
//   1. become an accessory (agent) app — no Dock icon, no menu bar item,
//   2. install the app delegate that boots the socket server + notch UI,
//   3. run the AppKit event loop.
let app = NSApplication.shared
let delegate = NotchideAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
