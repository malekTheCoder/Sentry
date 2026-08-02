# MacStat + Claude Code hooks

MacStat ships a small CLI, `macstat`, that talks to the running `MacStat.app`
over the same local XPC connection `MacStatMCP` uses — no MCP round-trip
required. Two of Claude Code's documented hook events plug into it directly.

Both hooks require `MacStat.app` to be running, and require the
corresponding MCP tool to be enabled in **MacStat → Settings → AI Access**
(`preflight_check` for the `PreToolUse` hook, `get_session_resource_report`
for the `Stop` hook — both are read tools, enabled by default).

## 1. `PreToolUse` — don't run a heavy command while the Mac is cooking

Claude Code's `PreToolUse` hook can deny a pending tool call by exiting with
code `2`; whatever the hook writes to stderr is fed back to the model as
context for why. `macstat hook pretooluse` wraps exactly this: it calls
MacStat's `preflight_check` (thermal pressure, SoC temp, CPU load, battery),
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
            "command": "macstat hook pretooluse"
          }
        ]
      }
    ]
  }
}
```

`matcher: "Bash"` runs the check before every shell command — reasonable
default, since MacStat can't distinguish "about to run a 40-minute build"
from "about to run `ls`" without inspecting the command itself. If that's too
aggressive, narrow the matcher to specific commands via Claude Code's own
matcher syntax, or wrap `macstat hook pretooluse` in a script that only
proceeds for command lines containing `make`, `xcodebuild`, `npm run build`,
etc.

`macstat` must be on `PATH` — either install it there, or use an absolute
path in `command` (e.g. `/Applications/MacStat.app/Contents/MacOS/macstat
hook pretooluse`, or wherever your build output lands during development).

## 2. `Stop` — enrich the completion notification with real resource cost

Claude Code's `Stop` hook fires when the agent finishes responding. This
script pairs it with `macstat session-report` to post a native notification
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
            "command": "/bin/sh -c 'SUMMARY=$(macstat session-report --since=1800); osascript -e \"display notification \\\"$SUMMARY\\\" with title \\\"Claude Code finished\\\"\"'"
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
beyond `macstat` itself being on `PATH`.

## 3. `statusLine` — keep the Mac's numbers in view during a turn

Claude Code's status line is an external command whose stdout it renders, so
`macstat statusline --format compact` drops straight in. The wiring, a
script that merges it with Claude Code's own session JSON (model, directory),
and the one `|| true` that stops a missing Sentry from blanking the whole
status line, are in
[`../../docs/integrations/claude-code.md`](../../docs/integrations/claude-code.md).

The same page's siblings cover tmux (`docs/integrations/tmux.md`), Starship
(`starship.md`), and the streaming `macstat watch` command (`watch.md`).
Start at [`docs/integrations/README.md`](../../docs/integrations/README.md),
which also documents a **current limitation**: the XPC Mach service the CLI
connects to is not registered with `launchd` in this build, so no client can
reach `Sentry.app` yet. That affects the hooks on this page exactly as much
as it affects the status line.

## Sanity-check the CLI directly

```bash
macstat check
macstat wait --until=thermal_normal --timeout=60
macstat session-report --since=1800
macstat statusline --format plain
macstat watch --metric cpu.total_percent --interval 2s | head -5
```

`macstat check` exits `0` for "go" and `1` for "wait" — usable directly as a
shell guard outside of Claude Code too:

```bash
macstat check || echo "not a great time to kick off that build"
```
