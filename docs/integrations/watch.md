# `sentryctl watch` — streaming NDJSON

```bash
sentryctl watch --metric cpu.total_percent --interval 2s
```

One JSON object per line, forever, until you kill it:

```json
{"available":true,"metric":"cpu.total_percent","timestamp":"2026-08-02T09:41:12Z","unit":"percent","value":8.3}
{"available":true,"intervalSeconds":2.01,"metric":"cpu.total_percent","timestamp":"2026-08-02T09:41:14Z","unit":"percent","value":14.7}
```

Newline-delimited JSON rather than a JSON array, because an array has to be
closed before it parses and a stream is never closed. Every line stands
alone.

## Finding a metric ID

```bash
sentryctl watch --list-metrics
```

52 lines of `id<TAB>unit`, on stdout so it pipes into `fzf`, `grep`, or
`column -t`. Per-core (`cpu.core.3_percent`) and per-fan
(`thermal.fan_0_rpm`) IDs are **not** streamable — they are constructed
strings rather than enumerable metrics, and nothing can read them back out
of a snapshot. Asking for one says so specifically rather than reporting an
unknown metric.

## The fields

| Field | Meaning |
|---|---|
| `timestamp` | When **Sentry sampled the hardware** — not when the CLI received it. A captured stream is therefore a series of real observation times. |
| `metric`, `unit` | Restated on every line, because a stream has no enclosing array to carry the context and `jq` over a scrollback needs it. |
| `value` | The reading, or `null`. |
| `available` | `false` when this Mac (or this build) cannot read the metric. |
| `intervalSeconds` | Gap since the previous sample, **as actually used**. Absent on the first line, which has no predecessor. |

`value: null` with `available: false` is the shape you get for a metric this
Mac cannot report — an M-series Mac with no discrete GPU power counter, a
machine whose HID thermal bridge did not resolve, or `cpu.user_percent`,
which the collector never splits out from `cpu.system_percent`. It is never
`0`, and the `value` key is never simply omitted. A stream where
"unavailable" and "zero" look alike cannot be used as evidence later, which
is the main reason to keep one.

## Piping

```bash
sentryctl watch --metric thermal.soc_temp_c | head -20 > /tmp/thermal.ndjson
sentryctl watch --metric cpu.total_percent | jq --unbuffered 'select(.value > 80)'
sentryctl watch --metric battery.charging_watts >> ~/charging.log &
```

`| head` works properly: the process ignores `SIGPIPE`, notices `EPIPE` on
the first write nobody is reading, and exits **0**. It does not die on
signal 13, so `sentryctl watch ... | head -5 && echo done` prints `done`.

Output is unbuffered — a raw `write(2)` per line, not stdio — so a consumer
sees each sample as it happens rather than when a 4KB buffer fills. Add
`--unbuffered` to `jq` if you put one in the middle; `jq` buffers on its own.

## The rate limit, and what `watch` does about it

Sentry's MCP rate limiter (**Settings → AI Access**) defaults to 20
calls/minute and counts read tools too. `--interval 1s` asks for 60/minute,
i.e. three times the budget.

Rather than dying twenty seconds in — or, far worse, silently skipping
samples — `watch` widens its own interval each time it is refused, and says
so:

```
$ sentryctl watch --metric cpu.total_percent --interval 1s
{"available":true,"metric":"cpu.total_percent", ... }
...
sentry: rate-limited by Sentry; widening --interval to 2s. Raise the limit
in Settings → AI Access to stream faster.
sentry: rate-limited by Sentry; widening --interval to 4s. Raise the limit
in Settings → AI Access to stream faster.
```

Those go to stderr, so they never corrupt the NDJSON on stdout. The stream
then continues at 4s, and every subsequent line's `intervalSeconds` reports
4-ish rather than claiming to be a 1s stream. The ceiling is 60s.

To actually stream at 1s, raise the limit in Settings to at least 60/minute.

## Exit codes

| Situation | Behavior |
|---|---|
| Consumer closed the pipe (`\| head`) | Exit `0` |
| Sentry not running, or the read tool disabled | Exit `1`, reason on stderr, nothing on stdout |
| Rate-limited mid-stream | Widen and continue; no exit |
| `--metric` missing, unknown, or per-core | Exit `1` with a specific message |
| `--interval` unparseable or zero | Exit `1` |

A denial on the *very first* sample is never backed off — the app not
running and the tool being disabled are conditions that do not resolve by
waiting, and hanging in the hope that they might is the one behavior a
script cannot recover from.

`--interval` accepts `500ms`, `1s`, `2m`, `1h`, or a bare number of seconds.
Compound forms (`1h30m`) are rejected rather than partially parsed.
