# Integrating `macstat` into things you already run

`macstat` is the shell-facing half of Sentry. It talks to the running
`Sentry.app` over the same local XPC connection `MacStatMCP` uses, so it
adds no new data path, no new permission model, and no second sampling loop
— just a different transport with ergonomics aimed at a script instead of
an LLM tool call (plan §21.2).

Everything here is a config snippet. None of it requires Sentry to know the
tool it is being embedded in.

| Page | What it sets up |
|---|---|
| [`tmux.md`](tmux.md) | `status-right` showing live battery/CPU/temperature |
| [`starship.md`](starship.md) | A `custom` module in your shell prompt |
| [`claude-code.md`](claude-code.md) | Claude Code's `statusLine`, plus the hooks in [`../../integrations/claude-code/README.md`](../../integrations/claude-code/README.md) |
| [`watch.md`](watch.md) | Streaming NDJSON into `jq`, a log file, or a chart |

## Two things to get right first

### 1. The binary lives inside the app bundle

```bash
/Applications/Sentry.app/Contents/MacOS/macstat --help
```

It is not on `$PATH` by default and it cannot simply be copied elsewhere:
it links `MacStatKit.framework` through `@executable_path/../Frameworks`, so
a loose copy dies in dyld before `main` runs. Symlink it instead:

```bash
ln -s /Applications/Sentry.app/Contents/MacOS/macstat /usr/local/bin/macstat
```

A symlink is fine — dyld resolves `@executable_path` against the *real* path
behind the link. Every snippet in these pages assumes `macstat` resolves.

### 2. Command-line access has to be set up, once

`macstat` and the stdio MCP server do not talk to `Sentry.app` directly.
They go through a small background item — a LaunchAgent macOS starts on
demand — that tells them where the running app is. It is not registered
until you ask for it:

**Sentry → Settings → AI Access → Set Up Command-Line Access.**

Until you do, every snippet on these pages fails with a message that says so:

```
macstat: Couldn't reach Sentry: its command-line bridge isn't available
(Couldn’t communicate with a helper application.).
...
  1. In Sentry, open Settings ▸ AI Access and choose "Set Up Command-Line Access".
  2. If you've already done that, open System Settings ▸ General ▸ Login Items &
     Extensions and make sure Sentry's background item is switched on.
```

Sentry running is not enough on its own, which is the one genuinely
surprising thing about this and the reason the message spells it out.

### 3. Sentry has to be running, with the read tool enabled

`macstat` reads nothing from the hardware itself. With the bridge set up but
`Sentry.app` not running, you get a non-zero exit and a message that says
*that* specifically — the bridge answered, so the tool knows the app is the
missing piece:

```
macstat: Couldn't reach Sentry: Sentry's command-line bridge is running, but
Sentry hasn't connected to it. Sentry is probably not running.
```

If it *is* running but MCP access is off, you get the reason from
**Settings → AI Access** instead. `get_system_snapshot` is a read tool and
is enabled by default, but the master switch (`mcpServerEnabled`) is off
until you turn it on — a deliberate default, not an oversight.

None of these cases ever produces a fabricated reading. This is worth
stating plainly because a status line is the easiest place in a system to
get away with one.

## The XPC registration bug, and what is still unverified

**This used to say that none of the snippets on these pages could return
data on a stock build. That was true, and it has been fixed.** The history is
worth keeping because the failure mode was so misleading.

`AppDelegate.startMCPListener()` created an `NSXPCListener(machServiceName:
"dev.malekswilam.macstat.xpc")`, and nothing in the project had ever
registered that name with `launchd` — no `MachServices` declaration, no
registered helper carrying one. `NSXPCListener` reports a failed check-in
nowhere at all, so the app looked completely healthy while every client of
that service failed, and the error message they printed blamed the app for
not running.

The fix is a bundled LaunchAgent (`SentryMCPBridge`) registered through
`SMAppService`, which owns the Mach service and hands clients a direct
connection to the running app. The obvious repair — declare the name and
keep the app's own listener — does not work, and was measured rather than
assumed: only the process `launchd` itself started as the job may vend that
job's Mach service, and Sentry is started by you, not by launchd. See
`MacStatKit/MCPBridge/MCPBridgeContract.swift` for the experiment.

### What is still unverified, stated plainly

`SMAppService` will only register a helper signed with the same real Team ID
as the app registering it. On a build made without a Developer ID
certificate, registration **cannot** succeed. So on such a build:

* **Set Up Command-Line Access reports the refusal verbatim** and the
  section stays in its "not set up" state. It does not pretend.
* `macstat` and the stdio MCP server fail with the message above, which
  names that as the likely cause.
* Everything else in Sentry is unaffected, **including MCP over HTTP**
  (Settings → AI Access → Remote Access), which uses a different transport
  and never went through this path.

What that means for these pages: the command surface, exit codes, formats
and failure behavior below are all real and exercised. A *successful* round
trip to a live `Sentry.app` requires a signed build, and on an unsigned one
these snippets will still fail — honestly, and for a reason they now name
correctly.
