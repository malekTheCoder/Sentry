---
layout: default
title: Support
---

# Support

Support for Sentry happens on GitHub Issues:

**[github.com/malekTheCoder/Sentry/issues](https://github.com/malekTheCoder/Sentry/issues)**

Search the existing issues first — someone may have already reported yours. If not, open a new issue.

## What to include in a bug report

The more of this you include, the faster the bug gets fixed:

- **What happened**, and what you expected to happen instead.
- **Steps to reproduce**, if you can make it happen again.
- **Sentry version** — shown on the About screen in Settings.
- **macOS version** and Mac model (e.g. macOS 14.6 on a MacBook Air M2). Apple menu → About This Mac.
- **Which part of the app** — the menu bar, the Dashboard window, a widget, the iPhone or Watch app, fan control, alerts, remote sync, or the AI/MCP interface.
- **A screenshot**, if the problem is visible.
- **A crash log**, if the app crashed — see below.

## Getting a crash log

When an app crashes, macOS writes a crash report to `~/Library/Logs/DiagnosticReports`. To find it:

1. In Finder, choose **Go → Go to Folder…** and paste `~/Library/Logs/DiagnosticReports`. (Or open **Console.app** and click **Crash Reports** in the sidebar.)
2. Look for `.ips` files whose names start with the process that crashed, plus a date — Sentry has three:
   - `Sentry-….ips` — the main Mac app
   - `SentryFanDaemon-….ips` — the fan-control helper
   - `SentryMCPBridge-….ips` — the AI/MCP bridge
3. Attach the most recent matching file to your issue. If GitHub rejects the `.ips` extension, rename it to `.ips.txt` or paste its contents into the issue in a code block.

Crash logs contain no personal data beyond file paths, which include your macOS username — skim the file before posting if that matters to you, and feel free to search-and-replace it.
