# Starship prompt

In `~/.config/starship.toml`:

```toml
[custom.sentry]
command = "sentryctl statusline --format compact"
when = true
shell = ["sh", "-c"]
format = "[$output]($style) "
style = "dimmed white"
```

Use `--format nerdfont` instead if your terminal font is a Nerd Font — the
glyphs are narrower and align better in a prompt than emoji do.

## Set `command_timeout`

Starship's default `command_timeout` is 500ms, and it kills a custom module
that exceeds it *and prints a warning into your prompt*. Add this near the
top of `starship.toml`:

```toml
command_timeout = 1000
```

This is belt-and-braces, not a workaround. `sentryctl statusline` already
enforces its own 50ms budget against the XPC connection, which is the part
that can plausibly be slow. What that budget cannot cover is process startup
— dyld resolving `SentryKit.framework` and spinning up the Swift runtime
happens before any of this command's code runs, and on a cold page cache
that alone can approach Starship's default. Raising the outer timeout costs
nothing on a warm machine and avoids a spurious warning on a cold one.

Starship's `command_timeout` is also the direct precedent for the internal
budget (plan §21.5): a prompt command that blocks blocks the shell, and a
developer will remove a tool that makes their terminal feel slow long before
they will investigate why it does.

## Only show it when there's a battery

```toml
[custom.sentry]
command = "sentryctl statusline --format compact"
when = "sentryctl statusline --format plain | grep -q batt="
```

`when` runs a command and shows the module only on exit 0. This particular
predicate doubles the number of invocations per prompt, which matters
against the 20 calls/minute rate limit — prefer `when = true` unless you
genuinely switch between machines with and without batteries.

## Reading the output

```
🔌78%  45W  ⚙️12%  🌡️62°C
```

- `🔋` / `🔌` — on battery / plugged in.
- The wattage is charging input while charging and system draw otherwise.
  `--format plain` spells out which (`charging=1` or `charging=0`); the
  glyph carries the same information more compactly.
- Segments Sentry cannot read are **absent**, not zero. A Mac whose thermal
  sensors this build cannot reach shows three segments, not `🌡️0°C`.
- A trailing `⏳2m` means the app did not answer in time and this is the
  last reading, two minutes old.

## Exit codes

| Situation | stdout | Exit |
|---|---|---|
| Fresh reading | the line | `0` |
| App slow, recent reading cached | the line, plus `⏳<age>` | `0` |
| App slow, nothing usable cached | *(empty)* | `124` |
| App not running | *(empty)* | `1` |
| MCP access disabled in Settings | *(empty)* | `1` |

`124` matches `timeout(1)`, per plan §21.2. Everything explanatory goes to
stderr, which Starship discards — stdout carries the prompt text and
nothing else.
