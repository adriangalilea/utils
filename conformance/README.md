# Conformance

Three separate codebases claim to emit the same log line. This runs them and checks.

```sh
./run.sh
```

Each probe emits the same six events. Four print; two sit below the default `info` level and must not appear, so the ladder is checked alongside the format. The harness asserts every emitted line opens with a well-formed UTC stamp, strips the stamps (they differ every run), and diffs the remainder against [`expected.txt`](expected.txt).

## What each probe needs

| probe | needs | resolves the library via |
|---|---|---|
| `probes/go` | `go` | `go.mod`, pinned |
| `probes/ts` | `node`, `npm` | `package.json`, installed on first run |
| `probes/py` | `uv` | `uv run --with adrian-utils`, no venv to manage |

A missing toolchain is reported `SKIP`, not a failure. The exit code is non-zero only when a library that ran disagrees with the spec.

## Scope

Only the **record** line is checked, because it is the only output that must be identical across languages: it is what lands in files, gets grepped, and is read on another machine months later. Human rendering shares its symbol vocabulary by convention, but layout, color and indentation belong to each library.

## Adding a language

Add `probes/<lang>/` emitting the same six events, and one block in `run.sh` that runs it with `LOG_FORMAT=record LOG_TIME=1`, writes stderr to a file, and calls `check`. Nothing else changes: `expected.txt` is already the answer.
