#!/bin/sh
# Fail when bookshelf's copy of the bookends progress-bar painter has drifted.
#
#   sh tools/check_bar_parity.sh [path-to-bookends-checkout]
#
# lib/bookshelf_bar_paint.lua carries two regions copied byte-for-byte out of
# bookends_overlay_widget.lua (the painter state + colour-safe paint helpers,
# and BAR_STYLES + paintProgressBar), so a bar looks the same with or without
# bookends installed. bookends' file is 2700 lines of overlay code around
# them, so the whole file cannot be shared the way tools/check_token_parity.sh
# shares its files; this script cuts the same regions out of both by their
# boundary lines and compares those. lib/bookshelf_pacman_sprite.lua is a
# whole-file copy of bookends_pacman_sprite.lua and is compared as a file.
#
# Only the requires above the first region differ (bookends_colour >
# lib/bookshelf_color, bookends_pacman_sprite > lib/bookshelf_pacman_sprite).
#
# A missing bookends checkout is NOT a failure - contributors clone one repo.

here=$(cd "$(dirname "$0")/.." && pwd)
sibling=${1:-$here/../bookends.koplugin}

ours="$here/lib/bookshelf_bar_paint.lua"
theirs="$sibling/bookends_overlay_widget.lua"

if [ ! -f "$theirs" ]; then
    echo "SKIP  bar parity: no bookends checkout at $sibling"
    exit 0
fi

# region FILE START AFTER END: print from the first line starting with START
# to the first line equal to END that comes at or after a line starting with
# AFTER (empty AFTER = no such condition). Fixed strings, not patterns.
region() {
    awk -v s="$2" -v a="$3" -v e="$4" '
        !p && index($0, s) == 1 { p = 1; armed = (a == "") }
        p { print }
        p && !armed && index($0, a) == 1 { armed = 1 }
        p && armed && $0 == e { exit }
    ' "$1"
}

status=0
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

check() {
    name=$1; shift
    region "$ours" "$@" > "$tmp/ours"
    region "$theirs" "$@" > "$tmp/theirs"
    if [ ! -s "$tmp/ours" ] || [ ! -s "$tmp/theirs" ]; then
        echo "FAIL  $name: region boundary not found (ours $(wc -l < "$tmp/ours") lines, bookends $(wc -l < "$tmp/theirs") lines)"
        status=1
    elif diff_out=$(diff -u "$tmp/ours" "$tmp/theirs" 2>&1); then
        echo "ok    $name identical ($(wc -l < "$tmp/ours") lines)"
    else
        echo "FAIL  $name has DRIFTED from bookends:"
        printf '%s\n' "$diff_out" | sed 's/^/      /'
        status=1
    fi
}

check "painter helpers" \
    "-- Per-pacman animation frame counters" "" \
    "local bbPaintRect = OverlayWidget.bbPaintRect"
check "paintProgressBar" \
    "-- Canonical list of styles paintProgressBar" \
    "function OverlayWidget.paintProgressBar(" \
    "end"

if [ -f "$sibling/bookends_pacman_sprite.lua" ]; then
    if diff_out=$(diff -u "$here/lib/bookshelf_pacman_sprite.lua" \
                          "$sibling/bookends_pacman_sprite.lua" 2>&1); then
        echo "ok    pacman sprite identical"
    else
        echo "FAIL  bookshelf_pacman_sprite.lua has DRIFTED from bookends:"
        printf '%s\n' "$diff_out" | sed 's/^/      /'
        status=1
    fi
else
    echo "FAIL  bookends_pacman_sprite.lua is MISSING from $sibling"
    status=1
fi

if [ "$status" -ne 0 ]; then
    echo ""
    echo "The bar painter is copied from bookends and must stay identical."
    echo "Copy the intended version of each region over the other, then run"
    echo "both test suites."
fi

exit "$status"
