# utils

The umbrella for three sibling libraries that solve the same problems in three languages, and the place their one shared contract is written down and machine-checked.

| | install | source |
|---|---|---|
| Go | `go get github.com/adriangalilea/go-utils` | [go-utils](https://github.com/adriangalilea/go-utils) |
| TypeScript | `pnpm add @adriangalilea/utils` | [ts-utils](https://github.com/adriangalilea/ts-utils) |
| Python | `uv add adrian-utils` | [py-utils](https://github.com/adriangalilea/py-utils) |

**Nothing depends on this repo.** It is not a package, there is no code to install, and the libraries do not know it exists. It holds the spec and a harness that runs all three and diffs their output. Dependencies point one way, from here to them, so the contract can never become a coupling.

Each library states its own doctrine in its own idiom, in its own source, and is complete on its own terms. That is deliberate: a shared document that must be kept in sync with three implementations is a fourth thing to rot. What lives here is only what genuinely cannot live in any one of them, the agreement *between* them.

## The logging contract

Loggers usually serve one of two consumers and lie to the other. A CLI logger writes symbols and color for a human watching right now, and its output is useless in a log file six hours later because nothing carries a time. A daemon logger writes timestamped structured lines, and reading its output in a terminal is a chore. The libraries serve both by deciding, per process, which consumer is actually on the other end.

**Two independent decisions, both automatic, both forceable.**

| knob | values | default |
|---|---|---|
| `LOG_FORMAT` | `human` \| `record` | `human` when stderr is a TTY, `record` when it is not |
| `LOG_TIME` | `1` \| `0` | on in `record`, off in `human` |

An unknown value for either raises or panics. A confused program should scream.

`record` is the format a file collects: greppable, one line per event, machine-stable. `human` is symbols, color and indentation for a terminal. Time is a separate axis because the two questions are separate: a human who wants timestamps should not have to give up symbols, and a sink that stamps lines itself (journald, Cloudflare, a platform log drain) should not get them twice.

### The record line

This is the whole contract, and the only thing that must be identical across languages:

```
2026-08-07T12:34:56Z WARN  [api auth] token expired
└─ UTC RFC3339 ─┘ └─┬─┘ └───┬───┘ └──────┬──────┘
                 level word  scope      message
```

- **Timestamp**: RFC3339, UTC, second precision. Omitted entirely when `LOG_TIME=0`. UTC and not local because logs get read on a different machine, in a different timezone, months later.
- **Level word**: `ERROR` `WARN` `INFO` `DEBUG` `TRACE`, left-aligned in five columns, so messages line up and `rg WARN` works. Words rather than symbols because a symbol does not survive every viewer, and no one greps for `⚠`.
- **Scope**: bracketed, space-joined for nested scopes, omitted when unscoped.
- **Message**: verbatim, one line.

Human rendering is deliberately *not* part of the contract. Symbols are shared by convention (`⨯ ⚠ ✓ ○ ▶ • » ◦`), but layout, color and indentation are each library's business.

### Levels

`silent < error < warn < info < debug < trace`, read live from `LOG_LEVEL`, defaulting to `info`. An unknown level raises.

### Verbs are renderings, never levels

A verb says what happened; the level it prints at is fixed. This is why there is no `wait` level to accidentally filter, and no way for two verbs that mean the same thing to drift apart.

| verb | level | symbol |
|---|---|---|
| `error`, `fail` | error | `⨯` |
| `warn` | warn | `⚠` |
| `info` | info | (none) |
| `success` | info | `✓` |
| `wait` | info | `○` |
| `ready` | info | `▶` |
| `step` | info | `•` |
| `debug` | debug | `◦` |
| `trace` | trace | `»` |

In `record` rendering a verb prints as its level word; the symbol is a human-rendering affordance.

### Scope is the one composition primitive

`scope("api")` returns a child logger that tags its lines `[api]` and resolves its level from `API_LOG_LEVEL` before falling back to `LOG_LEVEL`. Scopes nest, and the most specific wins:

```
scope("api").scope("auth")   →   [api auth],  AUTH_LOG_LEVEL, then API_LOG_LEVEL, then LOG_LEVEL
```

The scope name is upper-cased and non-alphanumerics become `_` to form the variable name. This is what makes one noisy subsystem silenceable in production without touching code, and one suspect subsystem openable to `trace` while everything else stays quiet.

### Streams

Logs go to **stderr**. `stdout` is for data, so piping a tool's output never chokes on a log line. Where there is no stderr (browsers, edge runtimes), logs go to the platform console and `LOG_TIME` defaults off, because those platforms stamp lines themselves.

## Conformance

The record line is the one thing three separate codebases must agree on byte for byte, which makes it the one thing worth machine-checking. `conformance/` runs the same event sequence through all three libraries and diffs their output:

```sh
conformance/run.sh
```

```
go    PASS
ts    PASS
py    PASS
```

Each probe emits the same events, the harness asserts every line carries a well-formed UTC stamp, strips the stamps, and diffs against `conformance/expected.txt`. A drift in any library's format fails here. See [conformance/README.md](conformance/README.md) for what each probe needs installed.

## License

MIT
