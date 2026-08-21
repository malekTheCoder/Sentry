# Getting help

Support happens in one place: **[GitHub Issues](https://github.com/malekTheCoder/Sentry/issues)**.
Search the open issues first — someone may already have reported yours,
and a "me too" with your details on an existing issue is more useful than
a duplicate.

There is no support email at this time. For security problems, do **not**
open a public issue — see [`SECURITY.md`](../SECURITY.md) for how to
report privately.

One thing worth knowing: Sentry has zero telemetry — no crash reporting,
no analytics. If something breaks and you don't report it, nobody will
ever know. Your issue reports are literally the only signal there is.

## What to include in a report

- **macOS version** (Apple menu ▸ About This Mac) and hardware — Apple
  Silicon or Intel, and the model if you know it.
- **App version**, from the About screen (Settings ▸ About).
- **What happened, and what you expected instead.** Steps to reproduce if
  you have them; a screenshot if it's visual.
- **For sync issues:** whether the Mac and iPhone are on the same network,
  and the iOS version.
- **For command-line/AI issues:** whether you enabled the feature in
  Settings (it installs a helper only when you turn it on).
- **Logs**, if you can. Sentry logs to the unified log under the subsystem
  `dev.malekswilam.sentry`. Either filter Console.app to that subsystem,
  or run:

  ```sh
  log show --last 10m --predicate 'subsystem == "dev.malekswilam.sentry"'
  ```

  and attach the output covering the moment things went wrong.

## Crash logs

When a process crashes, macOS writes a crash report — a `.ips` file — to
`~/Library/Logs/DiagnosticReports`. Sentry has two processes that can
show up there:

| Process | What it is |
| --- | --- |
| `Sentry` | The app itself |
| `SentryMCPBridge` | The helper for command-line / AI access (only exists if you enabled it) |

### Finding the file

1. In Finder, choose **Go ▸ Go to Folder…** and paste
   `~/Library/Logs/DiagnosticReports`. (Or open **Console.app** and click
   **Crash Reports** in the sidebar.)
2. Look for files whose names start with one of the two process names —
   for example `Sentry-2026-08-13-091500.ips`. The timestamp in the name
   is when the crash happened; grab the one matching your incident.
3. Terminal alternative — list the most recent matching reports:

   ```sh
   ls -t ~/Library/Logs/DiagnosticReports | grep -E '^(Sentry|SentryMCPBridge)-' | head
   ```

   Both processes run as you, not as root, so both write to `~/Library`.
   Nothing Sentry ships runs with elevated privileges.

### Before you post it — redact

A crash report contains no measurements or settings — it is stack traces
plus process metadata — but it does include **file paths containing your
macOS username** (`/Users/yourname/…`), plus your Mac's model and OS
build. Open the `.ips` file in any text editor, search for your username,
and replace it (with `USER`, say) before posting. Skim the rest for
anything else you'd rather not publish; issues on this repository are
public and permanent.

### Attaching it to an issue

GitHub doesn't accept `.ips` as an attachment. Either rename your
redacted copy to end in `.txt`, or zip it, then drag it into the issue.
If the file is short, pasting its contents into the issue inside a fenced
code block works just as well.
