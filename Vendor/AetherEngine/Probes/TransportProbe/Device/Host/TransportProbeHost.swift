import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// AE#377. This app exists so the probe's test bundle has a host, which is the only way XCTest runs
// on a device destination. It does two things beyond existing, and both are there because the
// alternative failed silently once already:
//
//   1. It keeps the screen saver off. Arm D runs for fifteen minutes and can be asked for
//      forty-five; an Apple TV that goes to sleep suspends the host process and takes the held
//      connection with it, which would read as the origin having cut it.
//   2. It puts the resolved target on the television. The one configuration channel that reaches a
//      device is ProbeTarget.swift, and a run whose URL never arrived reports as a skipped suite,
//      green. Now the set is readable before the run rather than after it.
@main
struct TransportProbeHostApp: App {
    var body: some Scene {
        WindowGroup {
            HostView()
        }
    }
}

private struct HostView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("AetherEngine transport probe")
                .font(.title2)

            if let config = ProbeConfig.resolve() {
                Text(config.summary)
                    .font(.system(.callout, design: .monospaced))
                Text("Run the TransportProbe scheme's test action against this device.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No source URL.")
                    .font(.title3)
                Text("""
                    Put it in Tests/TransportProbe/ProbeTarget.swift and build again. Environment \
                    variables do not reach a test process on any tvOS destination, simulator \
                    included, so that file is the only channel. Without it the suite reports as \
                    skipped and the run is green and empty.
                    """)
                    .foregroundStyle(.secondary)
            }

            Text("Screen saver disabled while this app is in front, so a long arm is not cut short by the device sleeping.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
#if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
#endif
        }
    }
}
