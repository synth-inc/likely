import AppKit

// `Likely --eval …` runs tests headlessly and exits (see docs/EVALS.md): no menu bar item, no windows,
// no onboarding, nothing the running app depends on. Release builds accept only `--eval personal` and
// its safe options (EvalOptions.Policy.release); dev builds accept everything.
if EvalCLI.isRequested(CommandLine.arguments) { EvalCLI.main(CommandLine.arguments) }

// "Log details for troubleshooting" lasts one session at most: off at quit, and here in case the last
// session didn't quit cleanly. Before anything logs or opens a transcript.
Log.details.turnOff()

// Owner-only permissions, Spotlight exclusion, release builds' debug screenshots: before the
// coordinator (created with the delegate) touches the folders. Then encrypt older plaintext data.
DataProtection.prepareAtLaunch()
DataProtection.migrateInBackground()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
