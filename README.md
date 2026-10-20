# utils

The umbrella for four sibling libraries that solve the same problems in four languages, and the place their one shared contract is written down and machine-checked.

| | install | source |
|---|---|---|
| Go | `go get github.com/adriangalilea/go-utils` | [go-utils](https://github.com/adriangalilea/go-utils) |
| TypeScript | `pnpm add @adriangalilea/utils` | [ts-utils](https://github.com/adriangalilea/ts-utils) |
| Python | `uv add adrian-utils` | [py-utils](https://github.com/adriangalilea/py-utils) |
| Swift | `.package(url: "https://github.com/adriangalilea/swift-utils", …)`, product `Log` | [swift-utils](https://github.com/adriangalilea/swift-utils) |

**Nothing depends on this repo.** It is not a package, there is no code to install, and the libraries do not know it exists. It holds the spec, the schema and a harness that runs all four and diffs their output. Dependencies point one way, from here to them, so the contract can never become a coupling.

Each library states its own doctrine in its own idiom, in its own source, and is complete on its own terms. What lives here is only what cannot live in any one of them: the agreement between them.

## The logging contract

A program's telemetry is **one stream of events**. A log line is an event at an instant; a span is a piece of work with a start and an end, written as two events; every line written inside a span names it. Logs and traces are not two systems but two views of one stream, which is what lets a viewer go from a line to the span it happened in and back.

Four languages write the stream the same way, byte for byte, so a Go daemon, a TypeScript worker, a Python script and a Swift app can be read, merged and traced together.

### Writing

Every verb takes **a message, then optional fields**. The message says what happened, the fields say with what. No joining of pieces, no format strings, no inspecting argument types: what is written is what is stored.

| | TypeScript | Go | Python | Swift |
|---|---|---|---|---|
| a line | `log.info("ready")` | `Log.Info("ready")` | `log.info("ready")` | `log.info("ready")` |
| with fields | `log.warn("retrying", { attempt: 2 })` | `Log.Warn("retrying", F{"attempt": 2})` | `log.warn("retrying", attempt=2)` | `log.warn("retrying", ["attempt": 2])` |
| an error | `log.error("charge failed", { err })` | `Log.Error("charge failed", F{"err": err})` | `log.error("charge failed", err=e)` | `log.error("charge failed", ["err": error])` |

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
```swift
try await log.span("charge", ["amount": a]) { s in
    s.warn("retrying", ["attempt": 2])
    try await s.span("stripe") { c in … }
    s.set(["receipt": r])
}
```

A span has the verbs, `span` (a child), `set` (fields learned while it runs, carried on its end event) and `traceparent` (its W3C header value, to hand on). In TypeScript the span is the callback's argument and `log.span` returns what the callback returns; in Python it is a context manager; in Go `End(&err)` reads the error the function returns; in Swift the span is the closure's argument, `span` returns what the closure returns, and an error it throws ends the span failed and is rethrown (sync and async closures alike). Swift's `traceparent` is a `Traceparent` value, its string form the header.

**Work that does not fit a block opens and ends its span by hand.** A stream read across event handlers, a socket opened in one callback and closed in another, a response that outlives the function that started it: `begin` opens the span and returns it, `end` closes it, once (twice raises). The block forms above are `begin` and `end` round a block; Go's `Span` and `End` are this form already.

| | TypeScript | Go | Python | Swift |
|---|---|---|---|---|
| open | `const s = log.begin("upload", { size })` | `s := Log.Span("upload", F{"size": n})` | `s = log.begin("upload", size=n)` | `let s = log.begin("upload", ["size": n])` |
| end | `s.end()`, `s.end(err)` | `s.End(nil)`, `s.End(&err)` | `s.end()`, `s.end(err)` | `s.end()`, `s.end(error)` |

A span never ended stays open: a viewer draws it running, which is the truth about it.

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
| an error (an `Error`, a Go `error`, a Python exception, a Swift `Error`, whose `cause` is an `NSError`'s underlying error) | an object with, in this order, `type` (its class or type name), `message`, then when present `stack`, `cause` (an error, the same way), and for a `SourcedError` `source`, `operation`, `status`, `context` |
| an instant (`Date`, `time.Time`, `datetime`) | its event-time string |
| a duration (`time.Duration`, `timedelta`) | milliseconds, a number |
| bytes | base64, a string (as Go's `encoding/json` writes `[]byte`) |
| big integers, decimals | a string |
| arrays, maps, objects | JSON, recursively (Go: `encoding/json`; Python: dataclasses as dicts) |
| a reference back to an enclosing value | the string `"[circular]"` |
| a value with a JSON form of its own (`toJSON`, `MarshalJSON`, a dataclass) | that form |
| sets | arrays; maps with non-string keys, objects keyed by each key's string form |
| an absent value (JavaScript's `undefined`) | left out of an object, `null` in an array, as JSON does |
| anything else | the language's string form of it |

A number is written as JavaScript writes it (ECMAScript's Number-to-String, which Go's `encoding/json` also follows): `2.0` is `2`, `1e-7` is `1e-7`, `-0` is `0`. An error's `message` is the message it was given, without any prefix its own string form adds (a `SourcedError`'s source and operation are keys of their own); `status` and `context` appear only with a value (an empty context is none). A `cause` that is no error is written as one, `{"type", "message"}` from its type and string form, so a cause always has the error's shape. Ending a span with no error (TypeScript's `end()`, `end(undefined)` or `end(null)`; Go's `End(nil)` or a pointer to nil; Python's `end()`) is ok; a block that throws anything at all, `null` included, ends it failed.

### Rendering

| `LOG_FORMAT` | for | default |
|---|---|---|
| `human` | a person at a terminal: symbols, colour, fields dim after the message as `key=value`, an error's stack under it, a span as `○ charge` … `✓ charge 254ms` with what it holds indented | stderr is a TTY; browsers |
| `json` | everything else: a file, a pipe, journald, Vercel, Cloudflare | stderr is not a TTY; Workers |

`LOG_TIME=1|0` puts a dim local `HH:MM:SS` before human lines (default off). JSON always carries `time`.

The human rendering's layout and colour are each library's business; its symbols are the table above. One rule it keeps everywhere: an error's stack is printed once. A span that fails with an error a span inside it already failed with (the same error, passed up) prints its message, not its stack again. JSON writes both: they are two facts.

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

Whether a span is shown is decided once, when it begins, by its start event's level against its scope's threshold at that moment; its end follows that decision, so a viewer never meets an end without its start or a start whose end was filtered later. **A failure is never lost to that:** a hidden span that fails writes one line, verb `fail` at level error, its message the span's name and its fields the span's with `err` and `dur_ms`, as a line of its nearest shown span (no `phase`, so nothing waits to be paired with it). When a span is not shown, what it holds belongs to its nearest span that is: its lines carry that span's id, its child spans name it as parent, and its `traceparent()` names it, so a viewer never meets a parent that is not there. A remote span joined through `traceparent` counts as a shown ancestor: it is shown in its own process's stream, which a viewer merges with this one. A span with no shown ancestor hands on its own id, and the lines written in it carry no ids at all, as lines outside any span do: an id names a span a viewer can find.

### Service

`LOG_SERVICE` names the program in every event. Unset, it is the name of the executable or script without its extension. Where there is none (a Worker), it must be set, and the first JSON event says so by failing.

### The platform record

Where the platform keeps a log of its own (Apple's unified log, for Swift), a writer also records every event there as its JSON line, by **its own threshold**: `LOG_RECORD_LEVEL` (`setLogRecordLevel`), default `info`, apart from the stream's `LOG_LEVEL`. The stream is for whoever reads the process; the record is what a trace is gathered from later, so a command quiet at its terminal (`warn`) still records its spans. A span decides where it goes when it begins (the stream, the record, both) and its end follows. A stream read at a lower verbosity than the record may meet a line naming a span only the record holds; the record is the whole trace. `LOG_OSLOG=0` turns the record off.

### The record as a file

A record read back often (a trace gathered on demand) is kept as a file: `LOG_RECORD_FILE` (`setLogRecordFile`) names a path, and every event the record takes (`LOG_RECORD_LEVEL`) is appended there as its JSON line, the same bytes as the stream's `json` rendering, one `write` per line. Reading a file is a scan of what was written; a platform log is a scan of everything every program wrote (Apple's: seconds for an hour, a minute for a day).

- **Bounded.** When an append takes the file past 4 MiB, the writer renames it to the same path with `.1` before its extension (`authzd.jsonl` → `authzd.1.jsonl`, replacing an older one) and starts a new one: two generations, at most about 8 MiB. A reader reads `.1` then the current file.
- **Shared.** Several processes may name one file (a command line run many times at once): each line is one append, so lines never interleave; a writer whose file was rotated by another (its descriptor no longer the path's file) reopens the path before its next line.
- **Never in the way.** A record file that cannot be opened or written is one `warnOnce`, scope `record`, on the stream; the event still goes everywhere else. The directory is created with the file, private to the user (0700, the file 0600).

The file is the record: a collector, a trace command or another device reads it, or receives it shipped; nothing reads the process's stderr for it.

### Shipping

An event is written to stderr. With `LOG_SHIP` set it is also sent to that URL, as the same bytes: shipping changes no event and no key, so whatever reads a file reads what arrives.

| variable | setter | value |
|---|---|---|
| `LOG_SHIP` | `setLogShip` (`SetLogShip`, `set_log_ship`) | an http(s) URL. Every event that passes its threshold is also POSTed there |
| `LOG_SHIP_TOKEN` | `setLogShipToken` (`SetLogShipToken`, `set_log_ship_token`) | a bearer sent with each batch as `Authorization: Bearer <token>` (servers); a browser sends none, since anything in a page is public |

**The batch** is the exact JSON lines the stream writes (the `json` rendering, whatever `LOG_FORMAT` shows on stderr), in the order written, joined by `\n` with no trailing newline: the body of a `POST` with `Content-Type: text/plain;charset=utf-8`, the one type `navigator.sendBeacon` and a cross-origin `fetch` send without a preflight. At most 64 KB of UTF-8 (the beacon's limit) and 50 events. An event alone over 64 KB is not shipped: it stays on stderr and the writer warns once.

**A writer sends a batch** 2 seconds after its first event; at 50 events; when a span opened outside any span of this process ends (a root span, or one joined from a remote parent), so a request's whole trace leaves together; before the process exits on its own, where the runtime lets a library hook that (Node and Bun `beforeExit`, Python and Swift `atexit`); and in a browser immediately on `visibilitychange: hidden` and on `pagehide`, through `sendBeacon`. Where nothing can be hooked (Go, a Worker, a serverless function frozen after its response, an explicit exit), the program calls `flushLog` (`FlushLog`, `flush_log`): it sends what waits and returns once no batch is in flight. Several batches can be in flight, so they may arrive in any order; each holds its lines in the order written.

**The answer** is `204` when every line was stored, or `400` with `{"accepted":n,"rejected":[{"line":i,"why":"…"}]}` when some were refused (`line` counts from 1 within the batch; the accepted lines are stored). `401` is a missing or unknown bearer, `413` a body over 64 KB, `415` another content type. A writer reads any answer but `204` as a refused batch.

**Delivery** is at most once from a browser, and at least once from a server that retries. A collector drops a span event it already stored (the same `span_id` and `phase`), so a retried batch never doubles a span; lines have no identity of their own and may repeat.

**Shipping is never in the way.** A writer never blocks a write on it and never throws from it: a refused or lost batch is one `warnOnce`, scope `ship`, which ships with the next batch like any event. A malformed `LOG_SHIP` is a configuration error and raises, as every variable does.

A browser writes no `Authorization`, so a collector tells a page's batch by its `Origin` and its events' `service`, and answers it with `Access-Control-Allow-Origin` (a `fetch` that cannot read its answer reads as lost). A batch leaving a hidden page goes through `sendBeacon`, the one request a browser finishes after the page is gone.

### Web pages

How a page in a browser writes the stream, so any collector and any viewer read every site the same way. ui's `page-sensor` writes it, through ts-utils' logger; the fields are [`schema/page.schema.json`](schema/page.schema.json).

**A page shown is a span named `page`, and the root of its own trace.** Nothing is above it. A visit (one person's pages close together) is not in the stream: only the collector sees the caller, so it composes visits from pages, and a page learns nothing it would have to ask for first.

| in the browser | in the stream |
|---|---|
| a page shown: the first paint of a load, or a prerendered page activated | a `page` span starts, a new `trace_id` |
| a client-side route change | the `page` span ends; a new one starts, `nav: "soft"`, `from` the previous path |
| the tab hidden | the `page` span ends (hidden is the last moment a page reliably sends anything) |
| the tab shown again | a new `page` span, `nav: "resumed"`, same path |
| restored from the back/forward cache | a new `page` span, `nav: "bfcache"` |
| prerendered, never shown | nothing |
| a same-origin request | a `fetch` span, child of the page; its `traceparent()` goes on the request's `traceparent` header (never a cross-origin one: a header of ours would cost it a preflight) |
| the server handling it | `log.join(header)`: its spans are children of the `fetch` span, in the page's trace |
| a named event | a line through the page span: `page.info("main action", { label })` |
| an uncaught error, an unhandled rejection | an `error` line through the page span, `err` in its fields |

A `page` span's start carries `host`, `path` (the pathname, no query), `nav` (`navigate`, `reload`, `back_forward`, `prerender`, `soft`, `resumed`, `bfcache`), `from` on a soft navigation, `referrer` (the referring page's host, never its URL), `source` (`utm_source`, else `ref`, when the URL has one), `viewport` (`phone` under 640 px, `tablet` under 1024, else `desktop`), and what the site knows that a collector cannot: `place` (what a visitor would call where they are: a project, the studio), `route` (the route's pattern, `requests/:n`) and `build` (the deploy that served it, a git sha). `probe: true` when an automated browser drives it (`navigator.webdriver`), `staff: true` when the site says its owner is reading. A page span lives only while its page is on screen, so its `dur_ms` is the time it was seen. Its end adds, through `set`, `reached` (the `data-section` names that came on screen, in the order first seen) and, on the first page of a load only, the load's vitals `ttfb_ms`, `lcp_ms`, `inp_ms`, `cls`. A `fetch` span carries `method`, `path` (pathname, no query) and `kind` (`rsc`, `action`, `api`, `other`); its end adds `status`, or `aborted: true` for a request the page cancelled (a navigation superseded, which is no failure), and it ends failed on a network error or a status of 400 or more.

**What a page never writes:** a query string, a full URL (its own or a referrer's), an IP, a user agent, a cookie, or anything that names a person (`email`, `user`, `name`, `phone`: a server span that needs to say so says `signed_in: true`). Nothing is stored in the browser to recognise it later. **A browser that asks not to be tracked** (`navigator.globalPrivacyControl`, or Do Not Track) gets no `page` span and sends nothing at all.

### Configuration

Environment variables, each with a setter for code: `LOG_FORMAT` (`setLogFormat`), `LOG_TIME` (`setLogTime`), `LOG_LEVEL` and `{SCOPE}_LOG_LEVEL` (`setLogLevel`), `LOG_SERVICE` (`setLogService`), `LOG_RECORD_LEVEL` (`setLogRecordLevel`), `LOG_RECORD_FILE` (`setLogRecordFile`), `LOG_SHIP` (`setLogShip`), `LOG_SHIP_TOKEN` (`setLogShipToken`). For every one of them **the environment wins over code**: a setter is the program's own default, and the operator's variable, read live, overrides it. Values are matched without regard to case (`LOG_LEVEL=DEBUG` is `debug`), an empty variable is unset, and an unknown value raises or panics. A confused program should scream.

A malformed `traceparent` handed to `join` is warned about once per distinct value (bounded memory, as `warnOnce`); lines written through a joined logger outside any span carry no ids, as a process's lines outside its spans never do.

## Conformance

The event stream is the one thing four codebases must agree on byte for byte, which makes it the one thing worth machine-checking. `conformance/` runs the same sequence of events through all four libraries and diffs them:

```sh
conformance/run.sh
```

```
go     PASS   events · scope level · traceparent · ship
ts     PASS   events · scope level · traceparent · ship
py     PASS   events · scope level · traceparent · ship
swift  PASS   events · scope level · traceparent · ship
```

Each probe writes the same events. The harness checks every line is one JSON event with its keys in the contract's order, replaces what differs every run (times, ids, durations, stacks, error type names) with stable tokens that keep which ids are the same, and diffs the result against `conformance/expected.jsonl`. Two more runs check the level ladder (`API_AUTH_LOG_LEVEL=debug` opens one nested scope) and a trace continued from `TRACEPARENT`, and a fourth points `LOG_SHIP` at a local collector and proves the shipped bytes are the stderr bytes, over the contract's wire. See [conformance/README.md](conformance/README.md).

## License

MIT
