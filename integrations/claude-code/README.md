# Sentry + Claude Code hooks

Sentry ships a small CLI, `sentryctl`, that talks to the running `Sentry.app`
over the same local XPC connection `SentryMCP` uses — no MCP round-trip
required. Two of Claude Code's documented hook events plug into it directly.

Both hooks require `Sentry.app` to be running, and require the
corresponding MCP tool to be enabled in **Sentry → Settings → AI Access**
(`preflight_check` for the `PreToolUse` hook, `get_session_resource_report`
for the `Stop` hook — both are read tools, enabled by default).

## 1. `PreToolUse` — don't run a heavy command while the Mac is cooking

Claude Code's `PreToolUse` hook can deny a pending tool call by exiting with
code `2`; whatever the hook writes to stderr is fed back to the model as
context for why. `sentry hook pretooluse` wraps exactly this: it calls
Sentry's `preflight_check` (thermal pressure, SoC temp, CPU load, battery),
and denies the call with a real reason if now is a bad time to start
something heavy.

Add to `.claude/settings.json` (project or user-level):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "sentry hook pretooluse"
          }
        ]
      }
    ]
  }
}
```

`matcher: "Bash"` runs the check before every shell command — reasonable
default, since Sentry can't distinguish "about to run a 40-minute build"
from "about to run `ls`" without inspecting the command itself. If that's too
aggressive, narrow the matcher to specific commands via Claude Code's own
matcher syntax, or wrap `sentry hook pretooluse` in a script that only
proceeds for command lines containing `make`, `xcodebuild`, `npm run build`,
etc.

`sentryctl` must be on `PATH` — either install it there, or use an absolute
path in `command` (e.g. `/Applications/Sentry.app/Contents/MacOS/sentryctl
hook pretooluse`, or wherever your build output lands during development).

## 2. `Stop` — enrich the completion notification with real resource cost

Claude Code's `Stop` hook fires when the agent finishes responding. This
script pairs it with `sentry session-report` to post a native notification
that includes what the last while actually cost the machine — something none
of the existing zero-context "notify me when Claude Code finishes" tools
(`claudecodenotify`, `claude-notify`) can do, since they have no visibility
into the Mac's own resource history.

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/bin/sh -c 'SUMMARY=$(sentryctl session-report --since=1800); osascript -e \"display notification \\\"$SUMMARY\\\" with title \\\"Claude Code finished\\\"\"'"
          }
        ]
      }
    ]
  }
}
```

`--since=1800` reports over the last 30 minutes — adjust to roughly how long
your typical session runs. `osascript -e 'display notification ...'` is
macOS's built-in notification poster, so this needs no extra dependency
beyond `sentryctl` itself being on `PATH`.

## 3. `statusLine` — keep the Mac's numbers in view during a turn

Claude Code's status line is an external command whose stdout it renders, so
`sentryctl statusline --format compact` drops straight in. The wiring, a
script that merges it with Claude Code's own session JSON (model, directory),
and the one `|| true` that stops a missing Sentry from blanking the whole
status line, are in
[`../../docs/integrations/claude-code.md`](../../docs/integrations/claude-code.md).

The same page's siblings cover tmux (`docs/integrations/tmux.md`), Starship
(`starship.md`), and the streaming `sentryctl watch` command (`watch.md`).
Start at [`docs/integrations/README.md`](../../docs/integrations/README.md).

## Before any of this works: set up command-line access

**Everything on this page needs one piece of setup, and this used to be a
documented limitation rather than a step.** The XPC Mach service `sentryctl`
connects to was not registered with `launchd` in any build of this project,
so no client could reach `Sentry.app` at all — while `Sentry.app` looked
perfectly healthy and the error message blamed it for not running.

It is fixed. `Sentry.app` now ships a LaunchAgent that owns that service and
introduces clients to the running app, and you turn it on here:

**Sentry → Settings → AI Access → Set Up Command-Line Access.**

macOS may park it in *System Settings → General → Login Items & Extensions*
waiting for your approval; the Settings section says so explicitly when that
happens, rather than showing a tick.

Two things worth knowing before you wire hooks around it:

* **A running Sentry is not sufficient on its own.** If you skip this step,
  every hook and the status line fail — with a message that names this step,
  not with the old "Is Sentry running?".
* **On a build that wasn't signed with a Developer ID certificate, setup
  cannot succeed.** macOS only registers a background item whose signature
  matches the app registering it. Setup will say so verbatim, and the hooks
  on this page will keep failing. MCP over HTTP (Remote Access) uses a
  different transport and is unaffected either way.

## Sanity-check the CLI directly

```bash
sentryctl check
sentry wait --until=thermal_normal --timeout=60
sentry session-report --since=1800
sentryctl statusline --format plain
sentryctl watch --metric cpu.total_percent --interval 2s | head -5
```

`sentryctl check` exits `0` for "go" and `1` for "wait" — usable directly as a
shell guard outside of Claude Code too:

```bash
sentryctl check || echo "not a great time to kick off that build"
```
