#!/usr/bin/env bash
# Runs the same event sequence through all three libraries and proves their
# record output is identical. Every probe emits the same six events; the two
# below the default level must not appear, which checks the ladder at the same
# time as the line format.
#
# A missing toolchain is a SKIP, not a failure: someone with only Node should
# still be able to check the TypeScript half.
set -uo pipefail

cd "$(dirname "$0")"
STAMP='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z '
status=0

check() { # name, output-file
	local name=$1 out=$2

	if [ ! -s "$out" ]; then
		printf '%-6s FAIL   no output\n' "$name"
		status=1
		return
	fi

	# Every line must carry a well-formed UTC stamp before we strip them.
	local unstamped
	unstamped=$(grep -cvE "$STAMP" "$out")
	if [ "$unstamped" -ne 0 ]; then
		printf '%-6s FAIL   %s line(s) without a UTC stamp\n' "$name" "$unstamped"
		grep -vE "$STAMP" "$out" | sed 's/^/         /'
		status=1
		return
	fi

	if diff -q <(sed -E "s/$STAMP//" "$out") expected.txt >/dev/null; then
		printf '%-6s PASS\n' "$name"
	else
		printf '%-6s FAIL   record output differs from expected.txt\n' "$name"
		diff <(sed -E "s/$STAMP//" "$out") expected.txt | sed 's/^/         /'
		status=1
	fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export LOG_FORMAT=record LOG_TIME=1

if command -v go >/dev/null; then
	(cd probes/go && go run . 2>"$work/go.out" >/dev/null)
	check go "$work/go.out"
else
	printf '%-6s SKIP   go not installed\n' go
fi

if command -v node >/dev/null && command -v npm >/dev/null; then
	[ -d probes/ts/node_modules ] || (cd probes/ts && npm install --silent --no-audit --no-fund >/dev/null 2>&1)
	(cd probes/ts && node probe.mjs 2>"$work/ts.out" >/dev/null)
	check ts "$work/ts.out"
else
	printf '%-6s SKIP   node not installed\n' ts
fi

if command -v uv >/dev/null; then
	(cd probes/py && uv run --quiet --with adrian-utils python probe.py 2>"$work/py.out" >/dev/null)
	check py "$work/py.out"
else
	printf '%-6s SKIP   uv not installed\n' py
fi

exit $status
