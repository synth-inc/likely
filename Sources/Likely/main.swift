import AppKit

// `Likely --eval …` runs eval cases headlessly and exits (see docs/EVALS.md); no UI is set up.
// Dev builds only: release builds don't contain eval mode.
#if LIKELY_DEV
if EvalCLI.isRequested(CommandLine.arguments) { EvalCLI.main(CommandLine.arguments) }
#endif

// Owner-only permissions, Spotlight exclusion, release builds' debug screenshots: before the
// coordinator (created with the delegate) touches the folders. Then encrypt older plaintext data.
DataProtection.prepareAtLaunch()
DataProtection.migrateInBackground()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
