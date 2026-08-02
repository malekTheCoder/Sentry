# tmux status bar

One line in `~/.tmux.conf`:

```tmux
set -g status-right '#(macstat statusline --format tmux)'
set -g status-interval 5
```

Reload with `tmux source-file ~/.tmux.conf`.

## What you get

```
#[fg=#E6EDF3]🔌78%  #[fg=#E6EDF3]45W  #[fg=#58A6FF]⚙️12%  #[fg=#F85149]🌡️62°C#[default]
```

tmux interprets the `#[fg=…]` sequences in `#()` output, so those become
real colors. They come from the theme you picked in Sentry's own settings —
`--format tmux` reads `themeID` out of
`~/Library/Application Support/MacStat/settings.json` and resolves it
against the same `Theme.builtInPresets` the menu bar draws from, so the
terminal and the menu bar agree without you configuring anything twice.

Two rules govern which color a segment gets:

- **Severity wins when there is any.** A CPU at 90% or a SoC at 96°C is
  drawn in the theme's `danger` token no matter what color the theme assigns
  that metric, because the palette is for telling metrics apart and the
  severity colors are for noticing.
- **Otherwise the theme's own per-metric color applies**, falling back to
  `textPrimary` for a metric the theme doesn't name.

The dark half of every theme color pair is used unconditionally. A CLI has
no `NSAppearance` to consult and tmux does not report the terminal's
background, so this is an assumption rather than a lookup — a documented one,
and the right bet for a terminal by a wide margin.

## `status-interval`

`status-interval 5` re-runs the command every five seconds. Do not set it to
`1`: Sentry's MCP rate limiter defaults to 20 calls/minute (**Settings → AI
Access**), and a one-second status bar spends three times that budget on its
own before any other tool asks for anything. Five seconds costs 12/minute
and leaves room.

If you do exceed it, the status bar goes blank rather than showing a wrong
number — `macstat statusline` treats a rate-limit denial as a denial, not as
a hint to guess.

## Why it will not hang your status bar

tmux runs `#()` commands asynchronously and caches the last output, so a
slow command degrades the *freshness* of the bar rather than the bar itself.
`macstat statusline` does not lean on that: it gives `Sentry.app` a hard
50ms to answer and then falls back to the last reading it saw, labeled with
its age:

```
🔌78%  45W  ⚙️12%  🌡️62°C  ⏳2m
```

Past fifteen minutes the fallback is dropped entirely and the command prints
nothing (exit 124), because at that point the numbers describe a machine
state that no longer exists. An empty status-right segment is the honest
rendering of "I don't know."

## Escaping

`#` is special to tmux. The snippet above is safe as written because the
`#(...)` is the *whole* value and everything inside it is a command, not a
format string. If you concatenate `macstat` with literal text containing a
`#`, double it (`##`) per tmux's own rules.
