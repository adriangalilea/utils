# utils

The umbrella for three sibling libraries that solve the same problems in three languages, and the place their one shared contract is written down and machine-checked.

| | install | source |
|---|---|---|
| Go | `go get github.com/adriangalilea/go-utils` | [go-utils](https://github.com/adriangalilea/go-utils) |
| TypeScript | `pnpm add @adriangalilea/utils` | [ts-utils](https://github.com/adriangalilea/ts-utils) |
| Python | `uv add adrian-utils` | [py-utils](https://github.com/adriangalilea/py-utils) |

**Nothing depends on this repo.** It is not a package, there is no code to install, and the libraries do not know it exists. It holds the spec, the schema and a harness that runs all three and diffs their output. Dependencies point one way, from here to them, so the contract can never become a coupling.

Each library states its own doctrine in its own idiom, in its own source, and is complete on its own terms. What lives here is only what cannot live in any one of them: the agreement between them.

## The logging contract

A program's telemetry is **one stream of events**. A log line is an event at an instant; a span is a piece of work with a start and an end, written as two events; every line written inside a span names it. Logs and traces are not two systems but two views of one stream, which is what lets a viewer go from a line to the span it happened in and back.

Three languages write the stream the same way, byte for byte, so a Go daemon, a TypeScript worker and a Python script can be read, merged and traced together.

### Writing

Every verb takes **a message, then optional fields**. The message says what happened, the fields say with what. No joining of pieces, no format strings, no inspecting argument types: what is written is what is stored.

| | TypeScript | Go | Python |
|---|---|---|---|
| a line | `log.info("ready")` | `Log.Info("ready")` | `log.info("ready")` |
| with fields | `log.warn("retrying", { attempt: 2 })` | `Log.Warn("retrying", F{"attempt": 2})` | `log.warn("retrying", attempt=2)` |
| an error | `log.error("charge failed", { err })` | `Log.Error("charge failed", F{"err": err})` | `log.error("charge failed", err=e)` |

**Verbs say what happened; each prints at a fixed level.** There is no `wait` level to filter by accident, and two verbs that mean the same thing cannot drift apart.

| verb | level | symbol (human) |
|---|---|---|
| `error`, `fail` | error | `⨯` |
| `warn` | warn | `⚠` |
| `warnOnce` (`WarnOnce`, `warn_once`) | warn, once per message and scope for the process (bounded memory) | `⚠` |
| `info` | info | none |
| `success` | info | `✓` |
| `wait` | info | `○` |
| `ready` | info | `▶` |
| `step` | info | `•`, indented |
| `debug` | debug | `◦` |
| `trace` | trace | `»` |

**Scope is the subsystem.** `scope("api")` returns a child logger whose events carry the scope; scopes nest (`scope("api").scope("auth")` is `["api", "auth"]`). A scope exists to be silenced or opened from the environment without touching code (Levels).

**A span is a piece of work, and a span is a logger.** What is written through it belongs to it; nothing else does. There is no ambient context: a function that logs inside a span takes the span. The span ends with its block, so it cannot be left open, and an exception or error ends it failed.

```ts
await log.span("charge", { amount }, async (s) => {
  s.warn("retrying", { attempt: 2 })
  await s.span("stripe", async (c) => { … })
  s.set({ receipt })
})
```
```go
s := Log.Span("charge", F{"amount": a})
defer s.End(&err)
s.Warn("retrying", F{"attempt": 2})
c := s.Span("stripe")
```
```python
with log.span("charge", amount=a) as s:
    s.warn("retrying", attempt=2)
    with s.span("stripe") as c:
        ...
    s.set(receipt=r)
```

A span has the verbs, `span` (a child), `set` (fields learned while it runs, carried on its end event) and `traceparent` (its W3C header value, to hand on). In TypeScript the span is the callback's argument and `log.span` returns what the callback returns; in Python it is a context manager; in Go `End(&err)` reads the error the function returns.

**A trace crosses processes explicitly.** `s.traceparent()` is the W3C `traceparent` value of a span (`00-<trace_id>-<span_id>-01`). Hand it on in an HTTP `traceparent` header, or in the `TRACEPARENT` environment variable of a process you spawn. On the other side, `log.join(value)` returns a logger whose spans are children of that remote span; `join` of an absent value (no header) returns the logger unchanged, and a malformed one is ignored with one `warn`, because it is input from outside. A process started with `TRACEPARENT` set joins it for its root spans, which is how a spawned script continues its parent's trace with no code.

### The event

What a program writes when it is not talking to a terminal: one JSON object per line, UTF-8, to **stderr**. One event is always one line, whatever its message holds. The schema is [`schema/event.schema.json`](schema/event.schema.json).

```json
{"time":"2026-10-12T12:20:39.123Z","level":"warn","verb":"warn","msg":"retrying","service":"checkout","scope":["payments"],"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","fields":{"attempt":2}}
```

Keys appear in this order, and only when they have a value:

| key | when | value |
|---|---|---|
| `time` | always | the instant, UTC, RFC3339 with milliseconds: `2026-10-12T12:20:39.123Z` |
| `level` | always | `error` `warn` `info` `debug` `trace` |
| `verb` | always | the verb that wrote it (the table above) |
| `msg` | always | the message; for a span's events, the span's name |
| `service` | always | the program (Service) |
| `scope` | scoped | the scope path, an array of strings |
| `phase` | a span's own events | `start` or `end` |
| `trace_id` | inside a span | 32 lowercase hex, W3C |
| `span_id` | inside a span | 16 lowercase hex: the span the event belongs to (a span's own events: that span) |
| `parent_id` | a span's own events, when it has a parent | 16 lowercase hex |
| `status` | `phase: end` | `ok` or `error` |
| `dur_ms` | `phase: end` | the span's length in ms, from a monotonic clock, rounded to 3 decimals |
| `fields` | fields given | an object, its keys at every depth in lexicographic order (a Go map has no order of its own, so every language sorts), an error's own keys excepted (Field values); on `phase: end`, the span's fields with what `set` added |

**A span is two events.** `start` (verb `wait`) when it begins, `end` when it ends: verb `success` and status `ok`, or verb `fail`, level `error`, status `error` and the error in `fields.err`. A viewer pairs them by `span_id`; a `start` with no `end` is a span still running, or a process that died inside it. Lines written through the span carry its `span_id` and `trace_id`; a root span makes a new `trace_id` (or takes `TRACEPARENT`'s).

**Field values** become JSON by one set of rules, so the same value reads the same from any language:

| value | becomes |
|---|---|
| string, finite number, boolean, null | itself |
| NaN, ±infinity | the string `"NaN"`, `"Infinity"`, `"-Infinity"` |
| an error (an `Error`, a Go `error`, a Python exception) | an object with, in this order, `type` (its class or type name), `message`, then when present `stack`, `cause` (an error, the same way), and for a `SourcedError` `source`, `operation`, `status`, `context` |
| an instant (`Date`, `time.Time`, `datetime`) | its event-time string |
| a duration (`time.Duration`, `timedelta`) | milliseconds, a number |
| bytes, big integers, decimals | a string |
| arrays, maps, objects | JSON, recursively (Go: `encoding/json`; Python: dataclasses as dicts) |
| a reference back to an enclosing value | the string `"[circular]"` |
| anything else | the language's string form of it |

### Rendering

| `LOG_FORMAT` | for | default |
|---|---|---|
| `human` | a person at a terminal: symbols, colour, fields dim after the message as `key=value`, an error's stack under it, a span as `○ charge` … `✓ charge 254ms` with what it holds indented | stderr is a TTY; browsers |
| `json` | everything else: a file, a pipe, journald, Vercel, Cloudflare | stderr is not a TTY; Workers |

`LOG_TIME=1|0` puts a dim local `HH:MM:SS` before human lines (default off). JSON always carries `time`.

The human rendering's layout and colour are each library's business; its symbols are the table above.

**Reading a file is the viewer's job.** `logs` (go-utils, `go install github.com/adriangalilea/go-utils/cmd/logs@latest`) reads events from files or stdin and renders them: human at a terminal, and in a pipe the grep line

```
2026-10-12T12:20:39.123Z WARN  [payments] retrying attempt=2
```

so `logs app.log | rg WARN` works as grepping a file did. A line that is not an event (a runtime panic, a library writing to stderr itself) is passed through as it is, never dropped. `logs -f` follows a file; `--level`, `--scope` and `--trace` filter.

### Levels

`silent < error < warn < info < debug < trace`, defaulting to `info`. A scoped event's threshold is read, live, from the most specific variable set:

```
scope ["api", "auth"]   →   API_AUTH_LOG_LEVEL, then API_LOG_LEVEL, then LOG_LEVEL, then setLogLevel(), then info
```

A scope path is upper-cased, non-alphanumerics become `_`, and segments join with `_`. The environment wins over code: `setLogLevel` (`SetLogLevel`, `set_log_level`) is the program's own default, and the operator's variable overrides it.

A span's two events are at their verbs' levels and filter like any event. When a span's events are filtered out, what it holds belongs to its nearest span that is shown: its lines carry that span's id and its child spans name it as parent, so a viewer never meets a parent that is not there.

### Service

`LOG_SERVICE` names the program in every event. Unset, it is the name of the executable or script without its extension. Where there is none (a Worker), it must be set, and the first JSON event says so by failing.

### Configuration

Environment variables, each with a setter for code: `LOG_FORMAT` (`setLogFormat`), `LOG_TIME` (`setLogTime`), `LOG_LEVEL` and `{SCOPE}_LOG_LEVEL` (`setLogLevel`, below the environment), `LOG_SERVICE` (`setLogService`). An unknown value of any of them raises or panics. A confused program should scream.

## Conformance

The event stream is the one thing three codebases must agree on byte for byte, which makes it the one thing worth machine-checking. `conformance/` runs the same sequence of events through all three libraries and diffs them:

```sh
conformance/run.sh
```

```
go    PASS   events · scope level · traceparent
ts    PASS   events · scope level · traceparent
py    PASS   events · scope level · traceparent
```

Each probe writes the same events. The harness checks every line is one JSON event with its keys in the contract's order, replaces what differs every run (times, ids, durations, stacks, error type names) with stable tokens that keep which ids are the same, and diffs the result against `conformance/expected.jsonl`. Two more runs check the level ladder (`API_AUTH_LOG_LEVEL=debug` opens one nested scope) and a trace continued from `TRACEPARENT`. See [conformance/README.md](conformance/README.md).

## License

MIT
