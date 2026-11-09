// main.swift: entry point for Phaedrus.app
//
//   Phaedrus             normal launch (by macOS for the Service, or by you → settings)
//   Phaedrus --settings  open the settings window
//   Phaedrus --once      terminal test: one dictation, transcript printed to stdout

import AppKit

MainActor.assumeIsolated {
    let controller = Controller()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = controller

    if CommandLine.arguments.contains("--once") {
        controller.onceMode = true
        // Start from the run loop, not from a main-queue block (see onMainRunLoop).
        controller.perform(#selector(Controller.runOnce), with: nil, afterDelay: 0)
    }
    app.run()
}
