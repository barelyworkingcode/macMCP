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
range="$1...$2"
self="scripts/ci-guards.sh"

TEST_PATH='(^|/)(test|tests|Tests|__tests__|testdata)/|_test\.go$|\.(test|spec)\.[cm]?[jt]sx?$|(^|/)test_[^/]*\.py$|_test\.py$'
SKIP_OR_FOCUS='\.Skip(f|Now)?\(|(^|[^A-Za-z0-9_])(it|test|describe|context)\.(skip|only)([^A-Za-z0-9_]|$)|\.only\(|(^|[^A-Za-z0-9_.])[xf](it|describe)\(|XCTSkip|@unittest\.skip|\.skipTest\(|pytest\.mark\.skip|pytest\.skip\('

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --text: a PR's own .gitattributes must not be able to hide files as binary.
# quotePath=false: paths come out as bytes, so patterns and the test-path
# regex see the real name.
gitdiff() { git -c core.quotePath=false diff --no-color --no-ext-diff --no-renames --text "$@"; }

gitdiff --name-only -z "$range" -- | tr '\0' '\n' > "$work/paths"
gitdiff --name-only -z --diff-filter=d "$range" -- | tr '\0' '\n' > "$work/added-paths"

# One row per added line, split into two files with matching line numbers:
# where ("path:line") and what (the text). Grepping "what" with -n and mapping
# the hit numbers back to "where" keeps the text out of the output.
gitdiff --src-prefix=a/ --dst-prefix=b/ --unified=0 "$range" -- | awk -v where="$work/where" -v what="$work/what" '
    /^diff --git / { header = 1; next }
    header && /^\+\+\+ / {
        path = substr($0, 5); sub(/\t$/, "", path)
        if (path ~ /^".*"$/) path = substr(path, 2, length(path) - 2)
        path = substr(path, 3); header = 0; next
    }
    header { next }
    /^@@ / { split($3, a, ","); line = substr(a[1], 2) + 0; next }
    /^\+/ { print path ":" line > where; print substr($0, 2) > what; line++ }
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

# mask: reads "path:line" or "path" rows and replaces each path that matches a
# hygiene pattern with its position in the changed-path list. The row's own
# text is tested, so a path git printed escaped is still caught. With invalid
# patterns nothing can be ruled out, so every path is replaced.
mask() {
    local row path suffix n
    while IFS= read -r row; do
        path=$row; suffix=
        case "$row" in *:[0-9]*) [ -n "${row##*:}" ] && [ -z "$(printf '%s' "${row##*:}" | tr -d 0-9)" ] && { path=${row%:*}; suffix=:${row##*:}; } ;; esac
        case "$patterns_state" in
            unset) printf '%s\n' "$row"; continue ;;
            ok) printf '%s\n' "$path" | grep -qaiE -f "$work/patterns" 2>/dev/null || { printf '%s\n' "$row"; continue; } ;;
        esac
        n=$(awk -v p="$path" '$0 == p { print NR; exit }' "$work/paths")
        printf 'changed path #%s%s\n' "${n:-?}" "$suffix"
    done
}

# where_of FILE: the "where" rows whose numbers are listed in FILE.
where_of() {
    awk 'FILENAME == ARGV[1] { want[$1] = 1; next } FNR in want' "$1" "$work/where"
}

has_label() {
    printf '%s' "${PR_LABELS:-}" | grep -qF "\"$1\""
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
    { grep -naE "$SKIP_OR_FOCUS" "$work/what" || true; } | cut -d: -f1 > "$work/skip-rows"
    hits=$(where_of "$work/skip-rows" | { grep -avE "^($self|.*\.md):[0-9]+$" || true; } | mask)
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
            where_of "$work/hygiene-rows"
            # Only names the PR leaves behind: deleting or renaming away a bad
            # name is the fix, not the offence.
            grep -aiE -f "$work/patterns" "$work/added-paths" 2>/dev/null || true
        } | mask | sort -u
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
