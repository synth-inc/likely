import AppKit

// `Likely --eval …` runs eval cases headlessly and exits (see docs/EVALS.md); no UI is set up.
// Dev builds only: release builds don't contain eval mode.
#if LIKELY_DEV
if EvalCLI.isRequested(CommandLine.arguments) { EvalCLI.main(CommandLine.arguments) }
#endif

// "Log details for troubleshooting" lasts one session at most: off at quit, and here in case the last
// session didn't quit cleanly. Before anything logs or opens a transcript.
Log.details.turnOff()

// Owner-only permissions, Spotlight exclusion: before the coordinator (created with the delegate)
// touches the folders. Then encrypt older plaintext data and delete older versions' screenshots.
DataProtection.prepareAtLaunch()
DataProtection.migrateInBackground()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
