# Conformance

Three separate codebases claim to write the same event stream. This runs them and checks.

```sh
./run.sh                       # the published libraries the probes pin
LOCAL=~/Developer ./run.sh     # the checkouts beside each other, before a release
```

Each probe writes the same sequence: lines with and without fields, a nested scope, an error as a field, a span holding a line and a child span with its own line, fields set while it runs, a span that fails, fields written out of order, and two lines below the default level that must not appear. `normalize.py` checks every line is one JSON event in the contract's shape (its keys a subset of the contract's, in its order; times in milliseconds UTC; ids lowercase hex; `fields` sorted at every depth, an error's keys in their fixed order), then replaces what differs every run with stable tokens: times by `T`, each trace and span id by `trace#n` and `span#n` in order of first appearance (so which events share an id is kept), durations by `D`, an error's type by `E`, its stack dropped. The result is diffed against the expected stream.

| run | environment | expected |
|---|---|---|
| events | | [`expected.jsonl`](expected.jsonl) |
| scope level | `API_AUTH_LOG_LEVEL=debug` | [`expected-scope.jsonl`](expected-scope.jsonl): the nested scope's debug line appears, nothing else |
| traceparent | `TRACEPARENT=00-0af7…319c-b7ad…3331-01` | [`expected-traceparent.jsonl`](expected-traceparent.jsonl): both root spans in that trace, under that span, ids kept as themselves |

## What each probe needs

| probe | needs | resolves the library via |
|---|---|---|
| `probes/go` | `go` | `go.mod`, pinned; `LOCAL`: a `replace` to the checkout |
| `probes/ts` | `node`, `npm` | `package.json`, pinned; `LOCAL`: the checkout, built |
| `probes/py` | `uv`, `python3` | `uv run --with adrian-utils`; `LOCAL`: the checkout |

A missing toolchain is reported `SKIP`, not a failure. The exit code is non-zero only when a library that ran disagrees with the contract.

## Adding a language

Add `probes/<lang>/` writing the same sequence, and one block in `run.sh` that hands its command to `probe`. Nothing else changes: the expected streams are already the answer.
