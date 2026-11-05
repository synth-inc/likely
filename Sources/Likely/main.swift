import AppKit

// `Likely --eval …` runs eval cases headlessly and exits (see docs/EVALS.md); no UI is set up.
if EvalCLI.isRequested(CommandLine.arguments) { EvalCLI.main(CommandLine.arguments) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
