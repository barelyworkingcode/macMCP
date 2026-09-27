#!/usr/bin/env bash
# PR guards, run by .github/workflows/guards.yml. The same file lives in every
# repo; change it everywhere or nowhere.
#
#   scripts/ci-guards.sh <base-sha> <head-sha>
#
# Env:
#   PR_LABELS         the PR's label names as a JSON array
#   HYGIENE_PATTERNS  newline-separated extended regexes, matched
#                     case-insensitively; unset means the hygiene guard warns
#                     and passes
#
# Output names file:line only, and a path that matches a hygiene pattern is
# replaced by its position in the changed-path list. Matched text and patterns
# never reach the log.
# Exit 0 when every guard passes, 1 when any fails, 2 on bad usage.
set -euo pipefail

# Byte semantics: under a UTF-8 locale GNU grep silently drops lines with
# invalid UTF-8 and BSD awk aborts on them. Case folding is ASCII-only as a result.
export LC_ALL=C

if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    echo "usage: $0 <base-sha> <head-sha>" >&2
    exit 2
fi
for sha in "$1" "$2"; do
    if ! git rev-parse --verify --quiet "$sha^{commit}" > /dev/null; then
        echo "$0: not a commit in this clone: $sha" >&2
        exit 2
    fi
done
range="$1...$2"
self="scripts/ci-guards.sh"

TEST_PATH='(^|/)(test|tests|Tests|__tests__|testdata)/|_test\.go$|\.(test|spec)\.[cm]?[jt]sx?$|(^|/)test_[^/]*\.py$|_test\.py$'
SKIP_OR_FOCUS='\.Skip(f|Now)?\(|(^|[^A-Za-z0-9_])(it|test|describe|context)\.(skip|only)([^A-Za-z0-9_]|$)|\.only\(|(^|[^A-Za-z0-9_.])(x(it|describe|test)|f(it|describe))\(|XCTSkip|@unittest\.skip|\.skipTest\(|pytest\.mark\.skip|pytest\.skip\('

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --text: a PR's own .gitattributes must not be able to hide files as binary.
# quotePath=false: -z output is raw bytes, so patterns and the test-path regex
# see the real name.
gitdiff() { git -c core.quotePath=false diff --no-color --no-ext-diff --no-renames --text "$@"; }

# Files are referred to by their position in this list everywhere below, never
# by a name parsed back out of diff text: git escapes some names in headers,
# and a name can itself be the secret. A newline inside a name becomes "?" so
# one file stays one line.
gitdiff --name-status -z "$range" -- | tr '\n\0' '?\n' | awk -v paths="$work/paths" -v deleted="$work/deleted" '
    NR % 2 == 1 { status = $0; next }
    { n++; print > paths; if (status == "D") print n > deleted }
'
touch "$work/paths" "$work/deleted"

# One row per added line, split into two files with matching line numbers:
# where ("file-index:line") and what (the text). Grepping "what" with -n and
# mapping the hit numbers back to "where" keeps the text out of the output.
# NULs become spaces because BSD awk ends a record at the first one.
gitdiff --unified=0 "$range" -- | tr '\000' ' ' | awk -v where="$work/where" -v what="$work/what" '
    /^diff --git / { file++; header = 1; next }
    header && /^@@ / { header = 0 }
    header { next }
    /^@@ / { split($3, a, ","); line = substr(a[1], 2) + 0; next }
    /^\+/ { print file ":" line > where; print substr($0, 2) > what; line++ }
'
touch "$work/where" "$work/what"

# Validated up front: a malformed pattern makes grep exit 2, which would
# otherwise read as "no match" and switch the whole denylist off.
patterns_state=unset
printf '%s\n' "${HYGIENE_PATTERNS:-}" | tr -d '\r' | grep -vE '^[[:space:]]*(#|$)' > "$work/patterns" || true
if [ -s "$work/patterns" ]; then
    set +e
    grep -aiE -f "$work/patterns" /dev/null 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -le 1 ]; then patterns_state=ok; else patterns_state=invalid; fi
fi

# matches_patterns FILE: the line numbers of FILE that match a hygiene pattern.
matches_patterns() {
    { grep -naiE -f "$work/patterns" "$1" 2>/dev/null || true; } | cut -d: -f1
}

# Files whose names may not be printed. With invalid patterns nothing can be
# ruled out, so that is all of them.
case "$patterns_state" in
    ok) matches_patterns "$work/paths" > "$work/secret-names" ;;
    invalid) awk '{ print NR }' "$work/paths" > "$work/secret-names" ;;
    *) : > "$work/secret-names" ;;
esac

# name: reads "file-index" or "file-index:line" rows and prints them with the
# file's name, or as "changed path #N" when the name may not be printed.
name() {
    awk -v secret="$work/secret-names" -v paths="$work/paths" '
        BEGIN {
            while ((getline l < secret) > 0) hide[l] = 1
            while ((getline l < paths) > 0) path[++n] = l
        }
        {
            i = $0; suffix = ""
            if (index($0, ":")) { i = substr($0, 1, index($0, ":") - 1); suffix = substr($0, index($0, ":")) }
            print ((i in hide) ? "changed path #" i : path[i]) suffix
        }
    '
}

# rows_of FILE: the "where" rows whose numbers are listed in FILE.
rows_of() {
    awk 'FILENAME == ARGV[1] { want[$1] = 1; next } FNR in want' "$1" "$work/where"
}

has_label() {
    printf '%s' "${PR_LABELS:-}" | tr -d '\n' | grep -qE "(^|[[,])[[:space:]]*\"$1\"[[:space:]]*(,|\\])"
}

indent() { sed 's/^/  /'; }

fail=0

guard_tests_only() {
    local tests others
    tests=$(grep -acE "$TEST_PATH" "$work/paths" || true)
    others=$(grep -avE "$TEST_PATH" "$work/paths" | grep -ac . || true)
    if [ "$tests" -eq 0 ] || [ "$others" -gt 0 ]; then
        echo "tests-only: ok"
    elif has_label tests-only; then
        echo "tests-only: $tests test file(s) and no code change, allowed by the tests-only label"
    else
        echo "::error::tests-only: the PR changes $tests test file(s) and nothing else; add the tests-only label if that is intended"
        fail=1
    fi
}

guard_skip_focus() {
    local hits
    # Exempt by index, so the check never depends on how a name prints.
    { grep -naE "^($self|.*\.md)$" "$work/paths" || true; } | cut -d: -f1 > "$work/exempt"
    { grep -naE "$SKIP_OR_FOCUS" "$work/what" || true; } | cut -d: -f1 > "$work/skip-rows"
    hits=$(rows_of "$work/skip-rows" | awk -F: 'FILENAME == ARGV[1] { skip[$1] = 1; next } !($1 in skip)' "$work/exempt" - | name)
    if [ -z "$hits" ]; then
        echo "skip-focus: ok"
    elif has_label skip-approved; then
        echo "skip-focus: added test skip or focus, allowed by the skip-approved label:"
        printf '%s\n' "$hits" | indent
    else
        echo "::error::skip-focus: added lines skip or focus tests; add the skip-approved label if that is intended:"
        printf '%s\n' "$hits" | indent
        fail=1
    fi
}

guard_hygiene() {
    local hits
    case "$patterns_state" in
        unset)
            echo "::warning::hygiene: HYGIENE_PATTERNS is not set; skipped"
            return ;;
        invalid)
            echo "::error::hygiene: HYGIENE_PATTERNS holds a pattern grep -E rejects; fix the secret"
            fail=1
            return ;;
    esac
    matches_patterns "$work/what" > "$work/hygiene-rows"
    hits=$(
        {
            rows_of "$work/hygiene-rows"
            # Only names the PR leaves behind: deleting or renaming away a bad
            # name is the fix, not the offence.
            awk 'FILENAME == ARGV[1] { gone[$1] = 1; next } !($1 in gone)' "$work/deleted" "$work/secret-names"
        } | name | sort -u
    )
    if [ -z "$hits" ]; then
        echo "hygiene: ok"
    else
        echo "::error::hygiene: added text matches the public-hygiene denylist at:"
        printf '%s\n' "$hits" | indent
        fail=1
    fi
}

guard_tests_only
guard_skip_focus
guard_hygiene
exit "$fail"
