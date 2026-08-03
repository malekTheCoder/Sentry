# Claude Code status line

Claude Code's status line is an external command, not a field list: it
launches whatever `statusLine.command` names, pipes the session JSON to it
on stdin, and renders that command's stdout. That makes `macstat statusline`
a drop-in ingredient — it needs to know nothing about Claude Code, and
Claude Code needs to know nothing about Sentry.

For the *hook* integrations (`PreToolUse` refusing to start a heavy build
while the Mac is throttled, `Stop` reporting what a turn cost), see
[`../../integrations/claude-code/README.md`](../../integrations/claude-code/README.md).
This page is only about the status line.

## Simplest version

`~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "macstat statusline --format compact"
  }
}
```

That ignores the session JSON on stdin entirely, which is fine — `macstat`
reads nothing from stdin and exits promptly whether anything is piped in or
not.

## Combined with Claude Code's own session fields

The interesting version puts Sentry's numbers next to the model and
directory. Save as `~/.claude/statusline.sh`, `chmod +x`:

```sh
#!/bin/sh
# Claude Code pipes session JSON on stdin. Read it once — reading it twice
# is not possible, stdin is a pipe.
session=$(cat)

model=$(printf '%s' "$session" | /usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("model",{}).get("display_name",""))' 2>/dev/null)
dir=$(printf '%s' "$session" | /usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("workspace",{}).get("current_dir",""))' 2>/dev/null)

# `|| true` matters: macstat exits non-zero when Sentry is unreachable, and
# a status line script that fails takes the whole status line down with it.
mac=$(macstat statusline --format compact 2>/dev/null) || true

printf '%s  %s  %s' "$model" "$(basename "$dir")" "$mac"
```

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

The `|| true` is the load-bearing line. `macstat statusline` deliberately
exits non-zero when it has nothing to show — `1` when Sentry is not running,
`124` when it timed out with no cached reading — because that is how a tmux
or Starship config distinguishes "briefly busy" from "gone." A shell script
under `set -e`, or one whose last command is `macstat`, propagates that and
Claude Code renders an empty status line. Swallow it deliberately, and
prefer the swallow to be visible in the script rather than implied.

## Which format

`compact` unless your terminal font is a Nerd Font, in which case
`nerdfont`. Do **not** use `tmux` here — Claude Code renders the string
literally, so tmux's `#[fg=…]` sequences would appear as text.

## Rate limit

Claude Code re-runs the status line command frequently. Sentry's MCP rate
limiter defaults to 20 calls/minute (**Settings → AI Access**), shared with
every other client — including any hooks you have configured, and any MCP
tools the agent itself calls during a turn. If the status line starts coming
up empty during busy turns, that budget is the first thing to check; raise
it in Settings rather than working around it.
