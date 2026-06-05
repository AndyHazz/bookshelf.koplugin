#!/bin/sh
# Run the pure-Lua Bookshelf test suites and report a single pass/fail.
#
#   sh tests/run.sh          # uses `lua` from PATH
#   LUA=luajit sh tests/run.sh
#
# A few suites depend on KOReader's runtime (native ffi/lfs modules or live
# UI widgets) and cannot run under a standalone interpreter. They are skipped
# here with the reason noted; exercise those on-device / under KOReader.
#
# Most suites report failure by printing a count rather than exiting non-zero,
# so a suite is treated as FAILED when it exits non-zero, prints a "FAIL "
# marker line, or reports a non-zero "<n> fail" count.

cd "$(dirname "$0")/.." || exit 2
LUA="${LUA:-lua}"

# Suites that cannot run standalone, keyed by basename. Keep the reason short.
skip_reason() {
    case "$1" in
        _test_colour.lua)         echo "lib/bookshelf_colour removed in v2.3.0 colour rework (test needs rewrite)";;
        _test_tall_screen.lua)    echo "needs KOReader native libs/libkoreader-lfs (pulled in via fonts)";;
        _test_text_segments.lua)  echo "needs KOReader native ffi/utf8proc";;
        *)                        echo "";;
    esac
}

fail_total=0
run_total=0
skip_total=0

for f in tests/_test_*.lua; do
    base=$(basename "$f")
    reason=$(skip_reason "$base")
    if [ -n "$reason" ]; then
        printf "SKIP  %-32s (%s)\n" "$base" "$reason"
        skip_total=$((skip_total + 1))
        continue
    fi
    run_total=$((run_total + 1))
    out=$("$LUA" "$f" 2>&1)
    code=$?
    if [ "$code" -ne 0 ] \
        || printf '%s\n' "$out" | grep -q "^FAIL " \
        || printf '%s\n' "$out" | grep -q "[1-9][0-9]* fail"; then
        printf "FAIL  %s\n" "$base"
        printf '%s\n' "$out" | sed 's/^/      /'
        fail_total=$((fail_total + 1))
    else
        summary=$(printf '%s\n' "$out" | grep -i "pass" | tail -1)
        printf "ok    %-32s %s\n" "$base" "$summary"
    fi
done

echo "------------------------------------------------------------"
echo "ran $run_total suites, $fail_total failed, $skip_total skipped"
[ "$fail_total" -eq 0 ] || exit 1
