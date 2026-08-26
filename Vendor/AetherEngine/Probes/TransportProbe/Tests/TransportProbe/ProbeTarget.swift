import Foundation

// The one file to edit before a device run.
//
// Environment variables still win, and they are how the macOS run is driven. No environment channel
// reaches a test process on a tvOS destination, simulator included: `TEST_RUNNER_`-prefixed settings
// are forwarded to UI-test runner apps, and a plain environment is not carried into a simulated
// process either. Both were measured, the first by a run that skipped the whole suite in silence,
// the second by a run that completed at the defaults and reported green. So tvOS reads its target
// from here, where nothing can silently drop it, and the host app prints what it read.
//
// Device/ compiles this file into the host app as well. Keep it free of any test-framework import.
enum ProbeTarget {

    /// The source URL, exactly as a player would be handed it. Redirects are followed once, the way
    /// the reader resolves before it pins. Empty disables the whole suite.
    static let sourceURL = ""

    /// Optional overrides. Zero means "use the default in ProbeConfig".
    static let holdSeconds: Double = 0
    static let windowSeconds: Double = 0
    static let megabitsPerSecond: Double = 0
    static let warmupMegabytes: Double = 0
    static let abortMegabytes: Double = 0

    /// A host that is not the origin, so a refusal can be told apart from the process's networking
    /// going deaf (#310). Empty keeps the default; "none" disables it.
    static let neutralCanaryURL = ""
}
