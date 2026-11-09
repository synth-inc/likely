import Foundation

/// Text and HTML reports for a run, optionally compared with the previous run of the same suite.
public enum EvalReport {
    // MARK: Text

    public static func textSummary(_ run: EvalRun, previous: EvalRun? = nil) -> String {
        let s = run.summary
        var lines: [String] = []
        lines.append("Suite \(run.suite) · \(run.agent) \(run.model) · k=\(run.k)\(run.isolated ? " · isolated" : "")"
                     + (run.interrupted == true ? " · INTERRUPTED (partial results)" : ""))
        var main = "Passed \(s.passed)/\(s.scored) (\(pct(s.passRate)))  hit@1 \(pct(s.hitAt1))  hit@3 \(pct(s.hitAt3))  hit@\(run.k) \(pct(s.hitAtK))"
        main += "  recall \(pct(s.meanRecall))  precision \(s.meanPrecision.map(pct) ?? "–")"
        lines.append(main)
        if let tools = run.tools { lines.append("Tools: \(tools.summary)") }
        var perf = "Median first file \(secs(s.medianFirstFileSeconds))  median total \(secs(s.medianTotalSeconds))"
        perf += "  cost \(s.totalCostUSD.map { String(format: "$%.4f", $0) } ?? "n/a")"
        perf += "  tool calls/case \(s.meanToolCalls.map { String(format: "%.1f", $0) } ?? "n/a")"
        if s.timeouts > 0 { perf += "  timeouts \(s.timeouts)" }
        if s.errors > 0 { perf += "  errors \(s.errors)" }
        lines.append(perf)
        if let previous {
            let p = previous.summary
            let differs = run.mismatches(with: previous)
            if !differs.isEmpty { lines.append("note: the previous run used different settings (\(differs.joined(separator: ", "))); not a like-for-like comparison") }
            let toolChanges = run.toolChanges(since: previous)
            if !toolChanges.isEmpty { lines.append("note: tools changed: \(toolChanges.joined(separator: ", "))") }
            lines.append("vs previous (\(previous.startedAt), \(previous.agent) \(previous.model)): pass \(pct(p.passRate)) → \(pct(s.passRate)), hit@1 \(pct(p.hitAt1)) → \(pct(s.hitAt1))")
            let changes = caseChanges(run, previous)
            if !changes.fixed.isEmpty { lines.append("  now passing: " + changes.fixed.joined(separator: ", ")) }
            if !changes.broke.isEmpty { lines.append("  now failing: " + changes.broke.joined(separator: ", ")) }
        }
        let failed = run.cases.filter { $0.score.scorable && !$0.pass }
        if !failed.isEmpty {
            lines.append("Failed: " + failed.map { $0.id + ($0.status == "ok" ? "" : " (\($0.status))") }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func caseChanges(_ run: EvalRun, _ previous: EvalRun) -> (fixed: [String], broke: [String]) {
        let before = Dictionary(grouping: previous.cases, by: \.id).mapValues { $0.allSatisfy(\.pass) }
        let after = Dictionary(grouping: run.cases, by: \.id).mapValues { $0.allSatisfy(\.pass) }
        var fixed: [String] = []
        var broke: [String] = []
        for (id, pass) in after.sorted(by: { $0.key < $1.key }) {
            guard let old = before[id] else { continue }
            if pass && !old { fixed.append(id) }
            if !pass && old { broke.append(id) }
        }
        return (fixed, broke)
    }

    // MARK: HTML

    public static func html(_ run: EvalRun, previous: EvalRun? = nil, previousPath: String? = nil) -> String {
        let s = run.summary
        var h = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Likely eval · \(esc(run.suite)) · \(esc(run.agent)) \(esc(run.model))</title>
        <style>
        :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --bg: #fff; --card: #f5f5f7;
                --pass: #1a7f37; --fail: #c62828; --warn: #b26a00; }
        @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --line: #3a3a3c; --bg: #1c1c1e; --card: #2c2c2e;
                --pass: #4ac26b; --fail: #ff6b6b; --warn: #f0a742; } }
        body { font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg);
               margin: 0 auto; max-width: 1100px; padding: 28px; }
        h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 28px 0 10px; }
        .muted { color: var(--muted); } code, .mono { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
        .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 10px; margin-top: 16px; }
        .tile { background: var(--card); border-radius: 10px; padding: 10px 12px; }
        .tile .v { font-size: 22px; font-weight: 600; font-variant-numeric: tabular-nums; } .tile .l { color: var(--muted); font-size: 12px; }
        .tile .d { font-size: 12px; }
        table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
        th { font-weight: 600; color: var(--muted); font-size: 12px; } td.n { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
        .pass { color: var(--pass); font-weight: 600; } .fail { color: var(--fail); font-weight: 600; } .warn { color: var(--warn); }
        .up { color: var(--pass); } .down { color: var(--fail); }
        details { border-bottom: 1px solid var(--line); padding: 8px 0; } summary { cursor: pointer; list-style: none; display: flex; gap: 10px; align-items: baseline; }
        summary::-webkit-details-marker { display: none; }
        .tag { display: inline-block; background: var(--card); border-radius: 4px; padding: 0 6px; font-size: 11px; color: var(--muted); margin-right: 3px; }
        ol { margin: 4px 0 4px 20px; padding: 0; } li { margin: 2px 0; } .box { margin: 6px 0 6px 26px; }
        </style></head><body>
        <h1>Likely eval: \(esc(run.suite))</h1>
        <div class="muted">\(esc(run.agent)) · \(esc(run.model)) · k=\(run.k) · timeout \(Int(run.timeoutSeconds))s\
        \(run.isolated ? " · isolated" : "")\(run.interrupted == true ? " · <span class=\"warn\">interrupted (partial results)</span>" : "") · prompt \(esc(run.promptHash))\(run.tools.map { " · tools: " + esc($0.summary) } ?? "") · Likely \(esc(run.likelyVersion))<br>
        \(esc(run.startedAt)) → \(esc(run.finishedAt))\(run.tags.isEmpty ? "" : " · tags: " + esc(run.tags.joined(separator: ", ")))</div>
        <div class="tiles">
        """
        let p = previous?.summary
        func tile(_ label: String, _ value: String, _ delta: String = "") -> String {
            "<div class=\"tile\"><div class=\"v\">\(value)</div><div class=\"l\">\(esc(label))</div><div class=\"d\">\(delta)</div></div>"
        }
        func deltaPct(_ now: Double, _ before: Double?) -> String {
            guard let before else { return "" }
            let d = (now - before) * 100
            if abs(d) < 0.5 { return "<span class=\"muted\">±0 vs prev</span>" }
            return "<span class=\"\(d > 0 ? "up" : "down")\">\(d > 0 ? "+" : "")\(Int(d.rounded())) pts vs prev</span>"
        }
        h += tile("passed", "\(s.passed)/\(s.scored)", deltaPct(s.passRate, p?.passRate))
        h += tile("hit@1", pct(s.hitAt1), deltaPct(s.hitAt1, p?.hitAt1))
        h += tile("hit@3", pct(s.hitAt3), deltaPct(s.hitAt3, p?.hitAt3))
        h += tile("hit@\(run.k)", pct(s.hitAtK), deltaPct(s.hitAtK, p?.hitAtK))
        h += tile("mean recall", pct(s.meanRecall), deltaPct(s.meanRecall, p?.meanRecall))
        h += tile("mean precision", s.meanPrecision.map(pct) ?? "–", s.meanPrecision.map { deltaPct($0, p?.meanPrecision) } ?? "")
        h += tile("median first file", secs(s.medianFirstFileSeconds))
        h += tile("median total", secs(s.medianTotalSeconds))
        h += tile("cost", s.totalCostUSD.map { String(format: "$%.4f", $0) } ?? "n/a")
        h += tile("tool calls / case", s.meanToolCalls.map { String(format: "%.1f", $0) } ?? "n/a")
        if s.timeouts + s.errors > 0 { h += tile("timeouts / errors", "\(s.timeouts) / \(s.errors)") }
        h += "</div>"

        if let previous {
            let changes = caseChanges(run, previous)
            h += "<h2>Compared with the previous run</h2><p class=\"muted\">\(esc(previous.startedAt)) · \(esc(previous.agent)) \(esc(previous.model))"
            h += " · prompt \(esc(previous.promptHash))\(previousPath.map { " · <code>\(esc($0))</code>" } ?? "")</p>"
            let differs = run.mismatches(with: previous)
            if !differs.isEmpty {
                h += "<p class=\"warn\">Different settings: \(esc(differs.joined(separator: ", "))). Not a like-for-like comparison.</p>"
            }
            let toolChanges = run.toolChanges(since: previous)
            if !toolChanges.isEmpty {
                h += "<p class=\"warn\">Tools changed: \(esc(toolChanges.joined(separator: ", "))) (previous: \(esc(previous.tools?.summary ?? "none"))).</p>"
            }
            h += "<p>Pass rate \(pct(previous.summary.passRate)) → <b>\(pct(s.passRate))</b>. "
            h += changes.fixed.isEmpty ? "" : "<span class=\"up\">Now passing: \(esc(changes.fixed.joined(separator: ", ")))</span>. "
            h += changes.broke.isEmpty ? "" : "<span class=\"down\">Now failing: \(esc(changes.broke.joined(separator: ", ")))</span>."
            if changes.fixed.isEmpty && changes.broke.isEmpty { h += "<span class=\"muted\">No case changed outcome.</span>" }
            h += "</p>"
        }

        if !run.byTag.isEmpty {
            h += "<h2>By tag</h2><table><tr><th>Tag</th><th>Cases</th><th>Passed</th><th>hit@1</th><th>hit@3</th><th>Recall</th><th>Median total</th></tr>"
            for (tag, t) in run.byTag.sorted(by: { $0.key < $1.key }) {
                h += "<tr><td>\(esc(tag))</td><td class=\"n\">\(t.scored)</td><td class=\"n\">\(t.passed) (\(pct(t.passRate)))</td>"
                h += "<td class=\"n\">\(pct(t.hitAt1))</td><td class=\"n\">\(pct(t.hitAt3))</td><td class=\"n\">\(pct(t.meanRecall))</td>"
                h += "<td class=\"n\">\(secs(t.medianTotalSeconds))</td></tr>"
            }
            h += "</table>"
        }

        h += "<h2>Cases</h2>"
        let previousByID = Dictionary(grouping: previous?.cases ?? [], by: \.id)
        for c in run.cases {
            let verdict = !c.score.scorable ? "<span class=\"warn\">UNSCORED</span>"
                : c.pass ? "<span class=\"pass\">PASS</span>" : "<span class=\"fail\">FAIL</span>"
            var badge = ""
            if let old = previousByID[c.id], c.score.scorable {
                let oldPass = old.allSatisfy(\.pass)
                if oldPass != c.pass { badge = c.pass ? " <span class=\"up\">(was failing)</span>" : " <span class=\"down\">(was passing)</span>" }
            }
            h += "<details><summary>\(verdict) <b>\(esc(c.id))</b>\(c.attempt > 1 ? " #\(c.attempt)" : "")\(badge)"
            h += " <span class=\"muted\">\(esc(c.query.map { "“\($0)”" }.joined(separator: " → ")))</span>"
            h += " <span class=\"muted\" style=\"margin-left:auto\">rank \(c.score.firstHitRank.map(String.init) ?? "–") · \(secs(c.totalSeconds))"
            h += c.costUSD.map { String(format: " · $%.4f", $0) } ?? ""
            h += "</span></summary><div class=\"box\">"
            h += "<div>\(c.tags.map { "<span class=\"tag\">\(esc($0))</span>" }.joined())"
            if c.status != "ok" { h += " <span class=\"warn\">\(esc(c.status))\(c.error.map { ": " + esc($0) } ?? "")</span>" }
            h += "</div>"
            h += "<p><b>Expected</b> (\(c.expectKind.rawValue)):</p><ol>"
            for e in c.expected {
                let found = c.score.matched.contains { EvalPath.same($0, e) || EvalPath.isInside($0, e) }
                h += "<li class=\"mono\">\(found ? "<span class=\"pass\">✓</span> " : "")\(esc(EvalPath.display(e)))</li>"
            }
            h += "</ol><p><b>Suggested</b>\(c.turns > 1 ? " (final turn of \(c.turns))" : ""):</p>"
            if c.suggestions.isEmpty { h += "<p class=\"muted box\">Nothing.</p>" } else {
                h += "<ol>"
                for sug in c.suggestions {
                    let hit = c.score.matched.contains { EvalPath.same($0, sug) }
                    h += "<li class=\"mono\">\(hit ? "<span class=\"pass\">✓</span>" : "<span class=\"muted\">·</span>") \(esc(EvalPath.display(sug)))</li>"
                }
                h += "</ol>"
            }
            if c.turns > 1 {
                for (i, turn) in c.turnSuggestions.enumerated().dropLast() {
                    h += "<p class=\"muted\">Turn \(i + 1): \(turn.isEmpty ? "nothing" : esc(turn.map(EvalPath.display).joined(separator: ", ")))</p>"
                }
            }
            if !c.refused.isEmpty {
                h += "<p class=\"muted\">Not shown by Likely: " + c.refused.map { esc(EvalPath.display($0.path)) + " (" + esc($0.reason) + ")" }.joined(separator: ", ") + "</p>"
            }
            h += "<p class=\"muted\">recall \(pct(c.score.recall)) · precision \(c.score.precision.map(pct) ?? "–")"
            h += " · first file \(secs(c.firstFileSeconds)) · total \(secs(c.totalSeconds))"
            h += " · tool calls \(c.toolCalls.map(String.init) ?? "n/a")"
            if let used = c.usedTools, run.tools?.isEmpty == false { h += used ? " · your tools" : " · without your tools" }
            if let t = c.transcriptPath { h += " · <a href=\"\(esc(t))\">transcript</a>" }
            if let pr = c.promptPath { h += " · <a href=\"\(esc(pr))\">prompt</a>" }
            h += "</p></div></details>"
        }
        h += "</body></html>\n"
        return h
    }

    // MARK: Formatting

    public static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    public static func secs(_ v: Double?) -> String { v.map { String(format: "%.1fs", $0) } ?? "–" }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
