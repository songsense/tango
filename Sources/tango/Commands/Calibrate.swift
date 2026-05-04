import ArgumentParser
import Foundation
import ClaudeToolCore

struct Calibrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Open the Tango menu-bar app's Calibrate… window for guided calibration."
    )

    func run() throws {
        // The interactive multi-phase calibration lives in the GUI (.app) so it
        // can show a live waveform and validation phases. Bring the menu-bar
        // app forward and instruct the user to click Calibrate.
        let osa = Process()
        osa.launchPath = "/usr/bin/osascript"
        osa.arguments = [
            "-e", "tell application \"Tango\" to activate"
        ]
        try? osa.run()
        osa.waitUntilExit()

        print("""
        Open Tango from the menu bar (👋 hand-tap icon) and choose Calibrate…
        The window guides you through:
          1. 3 seconds of ambient sampling (stay quiet)
          2. 5 deliberate pats (~1 s apart)
          3. Validation: 3 s silence + 3 confirmation pats

        Saved settings are written to:
          \(ConfigStore.shared.configURL.path)
        """)
    }
}
