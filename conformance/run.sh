#!/usr/bin/env bash
# Runs the same sequence of events through every library and proves their
# streams are identical: every line one JSON event in the contract's shape (keys,
# order, formats), and, with what differs every run replaced by stable tokens
# (normalize.py), the same stream as expected.jsonl. Five runs per library:
#
#   events       the default: the sequence, with the events below info absent
#   scope level  API_AUTH_LOG_LEVEL=debug opens the nested scope ["api","auth"]
#                and only it
#   traceparent  TRACEPARENT set: every root span joins that trace, under that
#                span
#   ship         LOG_SHIP pointed at a collector on 127.0.0.1 (ship.py): what
#                arrived is stderr byte for byte, over the contract's wire
#   colour       human lines into a pipe under each FORCE_COLOR / NO_COLOR /
#                TERM=dumb case: escapes exactly when the one rule says so
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

# colour <lang> <command...>: the one colour rule (README "Rendering"), with
# stderr a pipe: human lines carry escapes exactly when FORCE_COLOR asks for
# them, whatever NO_COLOR says, and never otherwise.
colour() {
	local lang=$1
	shift
	local case want painted bad=0
	for case in "|no" "FORCE_COLOR=1|yes" "FORCE_COLOR=|no" "FORCE_COLOR=0|no" "FORCE_COLOR=false|no" \
		"FORCE_COLOR=1 NO_COLOR=1|yes" "NO_COLOR=1|no" "TERM=dumb|no"; do
		want=${case#*|}
		# shellcheck disable=SC2086 # the case's assignments, word-split on purpose
		env -u FORCE_COLOR -u NO_COLOR LOG_FORMAT=human LOG_SERVICE=probe ${case%|*} "$@" \
			2>"$work/$lang-colour.err" >/dev/null
		painted=no
		grep -q $'\x1b\[' "$work/$lang-colour.err" && painted=yes
		if [ "$painted" != "$want" ]; then
			echo "${case%|*}: painted $painted, the rule says $want"
			bad=1
		fi
	done
	return $bad
}

# probe <lang> <command...>: the five runs, one result line.
probe() {
	local lang=$1
	shift
	local failed=() run
	for run in events scope traceparent ship; do
		if ! check "$lang" "$run" "$@" >"$work/$lang-$run.why" 2>&1; then
			failed+=("$run")
		fi
	done
	colour "$lang" "$@" >"$work/$lang-colour.why" 2>&1 || failed+=(colour)
	if [ ${#failed[@]} -eq 0 ]; then
		printf '%-6s PASS   events · scope level · traceparent · ship · colour\n' "$lang"
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
	# The package, not the workspace root (named ts-utils, which the probe
	# never imports: the published one ran in its place, silently).
	local_ts=()
	[ -n "${LOCAL:-}" ] && local_ts=("$LOCAL/ts-utils/packages/utils")
	# --prefer-online, as uv's refresh below: npm's cached index would not know
	# a version released minutes ago.
	if (cd "$work/ts-probe" && npm install --prefer-online --no-audit --no-fund ${local_ts[@]+"${local_ts[@]}"} >"$work/ts-install.log" 2>&1); then
		probe ts node "$work/ts-probe/probe.mjs"
	else
		printf '%-6s FAIL   npm install\n' ts
		sed 's/^/    /' "$work/ts-install.log" | tail -5
		status=1
	fi
else
	printf '%-6s SKIP   node not installed\n' ts
fi

if command -v uv >/dev/null; then
	# The floor is the first release that ships; the refresh makes uv ask
	# PyPI again instead of reusing what it resolved last time.
	with=(--refresh-package adrian-utils --with "adrian-utils>=0.9.2")
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
