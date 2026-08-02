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

### 2. Sentry has to be running, with the read tool enabled

`macstat` reads nothing from the hardware itself. If `Sentry.app` is not
running you get a non-zero exit and this on stderr:

```
macstat: Couldn't reach MacStat.app: Couldn’t communicate with a helper
application.. Is MacStat running?
```

If it *is* running but MCP access is off, you get the reason from
**Settings → AI Access** instead. `get_system_snapshot` is a read tool and
is enabled by default, but the master switch (`mcpServerEnabled`) is off
until you turn it on — a deliberate default, not an oversight.

Neither case ever produces a fabricated reading. This is worth stating
plainly because a status line is the easiest place in a system to get away
with one.

## Known limitation — the XPC service is not registered yet

**As of this writing none of the snippets on these pages will return data on
a stock build, and it is not a bug in the snippets.**

`AppDelegate.startMCPListener()` creates an `NSXPCListener(machServiceName:
"dev.malekswilam.macstat.xpc")`, but that name is not registered with
`launchd` anywhere in this project — there is no `MachServices` declaration
and no `SMAppService`-registered helper carrying one. A Mach service name
has to be checked in from a launchd job for a listener to receive anything,
so the listener resumes and then never hears from a client. Verified with
the app running:

```
$ launchctl print gui/501/dev.malekswilam.macstat.xpc
Could not find service "dev.malekswilam.macstat.xpc" in domain for user: 501
```

This affects **every** client of that service equally — `macstat check`,
`wait`, `status` and `session-report` (all of which predate this page) and
the stdio `MacStatMCP` binary, not just `watch` and `statusline`. Fixing it
is an app-packaging change (ship the listener as a registered login-item
helper, or vend the service from a bundled `.xpc` XPCService), not a CLI
change, so it is called out here rather than papered over.

What that means for these pages: the command surface, exit codes, formats
and failure behavior below are all real and exercised. What has not been
exercised end-to-end is a *successful* round trip to a live `Sentry.app`.
