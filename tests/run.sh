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
# (None currently: _test_tall_screen was skipped here for a long stretch, but
# its expectations were recalibrated to the shipped responsive layout and the
# widget now loads cleanly under the stub set, so it runs like the rest.)
skip_reason() {
    case "$1" in
        # Drives REAL SQLite (stubbing a database would only assert my own
        # assumptions back at me), so it needs KOReader's luajit and its
        # ffi/loadlib shim. It self-skips under a plain interpreter, but a
        # silent skip reported as "ok" is worse than no test - name it here so
        # the default run says so out loud. To actually run it:
        #   /usr/lib/koreader/luajit tests/_test_opds_db.lua
        _test_opds_db.lua)        echo "needs KOReader luajit for sqlite";;
        *)                        echo "";;
    esac
}

# Suites that need LuaJIT specifically (ffi), but nothing else from KOReader.
# These are NOT skipped: they run under `luajit` from PATH while every other
# suite stays on $LUA. Running the whole suite under one interpreter would be
# the simpler change and the wrong one -- lua and luajit disagree on things
# the other suites pin (number formatting, integer division), so the default
# `lua` run is load-bearing coverage.
needs_luajit() {
    case "$1" in
        _test_cover_disk_cache.lua) return 0;;
        *)                          return 1;;
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
    interp="$LUA"
    if needs_luajit "$base"; then
        if command -v luajit >/dev/null 2>&1; then
            interp=luajit
        else
            printf "SKIP  %-32s (%s)\n" "$base" "needs luajit for ffi"
            skip_total=$((skip_total + 1))
            continue
        fi
    fi
    run_total=$((run_total + 1))
    out=$("$interp" "$f" 2>&1)
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

# The vendored token-parity files must stay byte-identical with bookends
# (bookshelf #348). A drifted file shows up here as a failing line rather than
# as a bug report months later. Skips cleanly when the bookends checkout is not
# alongside this one, since contributors clone one repo.
if [ -f tools/check_token_parity.sh ]; then
    parity_out=$(sh tools/check_token_parity.sh 2>&1)
    parity_code=$?
    if [ "$parity_code" -ne 0 ]; then
        printf "FAIL  %s\n" "token parity vs bookends"
        printf '%s\n' "$parity_out" | sed 's/^/      /'
        fail_total=$((fail_total + 1))
    else
        printf "ok    %-32s %s\n" "token parity vs bookends" \
            "$(printf '%s\n' "$parity_out" | grep -c '^ok') files identical"
    fi
fi

echo "------------------------------------------------------------"
echo "ran $run_total suites, $fail_total failed, $skip_total skipped"
[ "$fail_total" -eq 0 ] || exit 1
