#!/bin/sh
# Fail when the vendored token-parity files have drifted between
# bookends.koplugin and bookshelf.koplugin.
#
#   sh tools/check_token_parity.sh [path-to-sibling-repo]
#
# The two plugins ship byte-identical copies of token_semantics.lua and
# token_conformance.lua so that a template copied between them renders the
# same string (bookshelf #348). Vendoring only works if divergence is loud,
# which is what this script is for: without it the whole approach rests on
# whoever edits one repo remembering that the other exists, and that is the
# assumption that failed twice already.
#
# A missing sibling checkout is NOT a failure - contributors clone one repo.
# Drift in a file that exists in both IS a failure.
#
# The two repos keep their copies at different paths (bookends is flat,
# bookshelf uses lib/) so the require paths differ while the CONTENT must not.
# That is also what makes a package.path collision harmless when a reader has
# both plugins installed: same bytes, either way round.

VENDORED="token_semantics.lua token_conformance.lua calibre_metadata.lua status_line.lua"

here=$(cd "$(dirname "$0")/.." && pwd)

# Work out which side we are on from where our own copies live.
if [ -f "$here/token_semantics.lua" ]; then
    ours_dir="$here"
    default_sibling="$here/../bookshelf.koplugin"
elif [ -f "$here/lib/token_semantics.lua" ]; then
    ours_dir="$here/lib"
    default_sibling="$here/../bookends.koplugin"
else
    echo "ERROR: no vendored token_semantics.lua found under $here" >&2
    exit 2
fi

sibling=${1:-$default_sibling}

if [ ! -d "$sibling" ]; then
    echo "SKIP  token parity: no sibling repo at $sibling"
    echo "      (clone it alongside this one to enable the check)"
    exit 0
fi

# The sibling may keep its copies flat or under lib/; accept either.
if [ -f "$sibling/lib/token_semantics.lua" ]; then
    theirs_dir="$sibling/lib"
elif [ -f "$sibling/token_semantics.lua" ]; then
    theirs_dir="$sibling"
else
    echo "SKIP  token parity: no vendored copies in $sibling"
    exit 0
fi

status=0
for f in $VENDORED; do
    if [ ! -f "$theirs_dir/$f" ]; then
        echo "FAIL  $f is MISSING from $theirs_dir"
        status=1
        continue
    fi
    if diff_out=$(diff -u "$ours_dir/$f" "$theirs_dir/$f" 2>&1); then
        echo "ok    $f identical"
    else
        echo "FAIL  $f has DRIFTED between the two repos:"
        printf '%s\n' "$diff_out" | sed 's/^/      /'
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo ""
    echo "These files are vendored and must stay byte-identical. Copy the"
    echo "intended version over the other, then run both test suites."
fi

exit "$status"
