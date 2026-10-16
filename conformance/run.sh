#!/usr/bin/env bash
# Runs the same sequence of events through all three libraries and proves their
# streams are identical: every line one JSON event in the contract's shape (keys,
# order, formats), and, with what differs every run replaced by stable tokens
# (normalize.py), the same stream as expected.jsonl. Four runs per library:
#
#   events       the default: the sequence, with the events below info absent
#   scope level  API_AUTH_LOG_LEVEL=debug opens the nested scope ["api","auth"]
#                and only it
#   traceparent  TRACEPARENT set: every root span joins that trace, under that
#                span
#   ship         LOG_SHIP pointed at a collector on 127.0.0.1 (ship.py): what
#                arrived is stderr byte for byte, over the contract's wire
#
# By default each library is the published one its probe pins. LOCAL=<dir>
# runs the checkouts in <dir> instead (<dir>/go-utils, <dir>/ts-utils built,
# <dir>/py-utils), which is how a library is checked before it is released.
#
# A missing toolchain is a SKIP, not a failure.
set -uo pipefail

cd "$(dirname "$0")"
here=$(pwd)
status=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

TRACEPARENT_VALUE=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01

# check <lang> <run> <command...>: runs a probe, normalizes its stderr, diffs.
check() {
	local lang=$1 run=$2
	shift 2
	local expected env=()
	case $run in
	events | ship) expected=expected.jsonl ;;
	scope) expected=expected-scope.jsonl env=(API_AUTH_LOG_LEVEL=debug) ;;
	traceparent) expected=expected-traceparent.jsonl env=(TRACEPARENT=$TRACEPARENT_VALUE) ;;
	esac
	local raw=$work/$lang-$run.err out=$work/$lang-$run.jsonl
	if [ "$run" = ship ]; then
		env LOG_FORMAT=json LOG_SERVICE=probe python3 "$here/ship.py" "$raw" "$@" || return 1
	else
		env LOG_FORMAT=json LOG_SERVICE=probe ${env[@]+"${env[@]}"} "$@" 2>"$raw" >/dev/null
	fi
	if [ ! -s "$raw" ]; then
		echo "no output"
		return 1
	fi
	if ! TRACE_ID=0af7651916cd43dd8448eb211c80319c PARENT_ID=b7ad6b7169203331 \
		python3 "$here/normalize.py" <"$raw" >"$out" 2>"$work/why"; then
		cat "$work/why"
		return 1
	fi
	if ! diff -u "$expected" "$out" >"$work/diff"; then
		sed 's/^/    /' "$work/diff"
		return 1
	fi
}

# probe <lang> <command...>: the four runs, one result line.
probe() {
	local lang=$1
	shift
	local failed=() run
	for run in events scope traceparent ship; do
		if ! check "$lang" "$run" "$@" >"$work/$lang-$run.why" 2>&1; then
			failed+=("$run")
		fi
	done
	if [ ${#failed[@]} -eq 0 ]; then
		printf '%-6s PASS   events · scope level · traceparent · ship\n' "$lang"
		return
	fi
	printf '%-6s FAIL   %s\n' "$lang" "${failed[*]}"
	for run in "${failed[@]}"; do
		echo "  $run:"
		sed 's/^/    /' "$work/$lang-$run.why"
	done
	status=1
}

if command -v go >/dev/null; then
	src=probes/go
	if [ -n "${LOCAL:-}" ]; then
		cp -R probes/go "$work/go-probe"
		(cd "$work/go-probe" && go mod edit -replace "github.com/adriangalilea/go-utils=$LOCAL/go-utils" && go mod tidy >/dev/null 2>&1)
		src=$work/go-probe
	fi
	(cd "$src" && go build -o "$work/go-probe-bin" .) && probe go "$work/go-probe-bin"
else
	printf '%-6s SKIP   go not installed\n' go
fi

if command -v node >/dev/null && command -v npm >/dev/null; then
	cp -R probes/ts "$work/ts-probe"
	if [ -n "${LOCAL:-}" ]; then
		(cd "$work/ts-probe" && npm install --silent --no-audit --no-fund "$LOCAL/ts-utils" >/dev/null 2>&1)
	else
		(cd "$work/ts-probe" && npm install --silent --no-audit --no-fund >/dev/null 2>&1)
	fi
	probe ts node "$work/ts-probe/probe.mjs"
else
	printf '%-6s SKIP   node not installed\n' ts
fi

if command -v uv >/dev/null; then
	# The floor is the first release that ships; the refresh makes uv ask
	# PyPI again instead of reusing what it resolved last time.
	with=(--refresh-package adrian-utils --with "adrian-utils>=0.8.1")
	# Editable: uv keys a built path dependency on its pyproject.toml, so a
	# plain --with would keep running the build from before a source edit.
	[ -n "${LOCAL:-}" ] && with=(--with-editable "$LOCAL/py-utils")
	probe py uv run --quiet --no-project "${with[@]}" python probes/py/probe.py
else
	printf '%-6s SKIP   uv not installed\n' py
fi

if command -v swift >/dev/null; then
	# Built in a copy so .build never lands in this repo; LOCAL swaps the
	# pinned revision for the checkout (Package.swift reads SWIFT_UTILS).
	cp -R probes/swift "$work/swift-probe"
	local_utils=()
	[ -n "${LOCAL:-}" ] && local_utils=(SWIFT_UTILS="$LOCAL/swift-utils")
	if env ${local_utils[@]+"${local_utils[@]}"} swift build -c release --package-path "$work/swift-probe" >"$work/swift-build.log" 2>&1; then
		probe swift "$(env ${local_utils[@]+"${local_utils[@]}"} swift build -c release --package-path "$work/swift-probe" --show-bin-path)/probe"
	else
		printf '%-6s FAIL   build\n' swift
		sed 's/^/    /' "$work/swift-build.log" | tail -20
		status=1
	fi
else
	printf '%-6s SKIP   swift not installed\n' swift
fi

exit $status
