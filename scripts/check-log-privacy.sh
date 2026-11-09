#!/bin/bash
# Checks that log lines can't leak personal content (see docs/PRIVACY.md, "The log"):
# every `public:` value in a Log.write line is on the reviewed list, LogSafe is only declared in
# LogPrivacy.swift, and nothing logs around Log.write. Unmarked string interpolations in Log.write
# don't compile at all (LogMessage). Also part of `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --filter 'LogPrivacySourceTests|LogMessageTests|LogDetailsSwitchTests|LogFileTests'
