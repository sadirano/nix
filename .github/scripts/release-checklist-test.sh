#!/usr/bin/env bash
#
# Drives release-checklist.sh against a stub `gh`, one scenario per case.
#
# The gate it tests runs exactly once per release, against a live repository,
# at the moment when getting it wrong is most expensive - so it is worth having
# the open/verify/close orchestration exercised on every commit instead. The
# stub answers from environment variables and records the arguments it was
# handed; nothing here touches the network.
#
# Run by `zig build ci`.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
S=".github/scripts/release-checklist.sh"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/stub"

cat > "$W/stub/gh" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the gh CLI: answers from env vars, records what it was given.
set -euo pipefail
all="$*"
printf '%s\n' "gh $all" >> "${STUB_LOG:-/dev/null}"
case "$1" in
label) exit 0 ;;
issue)
    case "$2" in
    list) printf '%s' "${STUB_NUM:-}"; [ -z "${STUB_NUM:-}" ] || printf '\n' ;;
    view)
        if [[ "$all" == *"--json labels"* ]]; then printf '%s\n' "${STUB_LABELS:-}"
        elif [[ "$all" == *"--json title"* ]]; then printf '%s\n' "${STUB_TITLE:-Release v0.11.0}"
        else cat "${STUB_BODY:?}"; fi
        ;;
    create|edit)
        for i in $(seq 1 $#); do
            if [ "${!i}" = "--body-file" ]; then j=$((i + 1)); cp "${!j}" "${STUB_CAPTURE:?}"; fi
        done
        [ "$2" = "create" ] && printf 'https://github.com/sadirano/nix/issues/77\n'
        exit 0
        ;;
    comment|close) exit 0 ;;
    esac
    ;;
release)
    case "$2" in
    view) printf 'auto-generated notes\n' ;;
    edit)
        for i in $(seq 1 $#); do
            if [ "${!i}" = "--notes-file" ]; then j=$((i + 1)); cp "${!j}" "${STUB_CAPTURE:?}"; fi
        done
        ;;
    esac
    ;;
esac
STUB
chmod +x "$W/stub/gh"
export PATH="$W/stub:$PATH"

# Refuse to run against the real gh. Without this guard a PATH that did not
# take effect turns a test run into issues filed on the repository, which is
# exactly what happened the first time this was written.
case "$(command -v gh)" in
"$W/stub/gh") ;;
*) echo "ABORT: gh resolves to $(command -v gh), not the stub"; exit 2 ;;
esac

export STUB_CAPTURE="$W/capture.md" STUB_LOG="$W/gh.log"
: > "$STUB_LOG"
head_sha="$(git rev-parse HEAD)"
# The stale-candidate test needs a sha with WATCHED changes after it, so it
# cannot be a fixed distance back: HEAD~3 silently stops testing anything the
# moment the last three commits are docs or CI only, and verify then correctly
# reports no drift while the test still demands a failure. Anchor to the newest
# commit that actually touched the watched paths and step one behind it.
#
# The list comes from the script itself (`paths`) rather than being repeated
# here. When these were two literals, adding a path to one of them would have
# left this fixture anchored to the old set - a test that still passes while
# measuring the wrong thing.
mapfile -t watched < <(bash "$S" paths)
[ "${#watched[@]}" -gt 0 ] || { echo "release-checklist.sh paths returned nothing" >&2; exit 1; }
watched_tip="$(git log -1 --format=%H -- "${watched[@]}")"
[ -n "$watched_tip" ] || { echo "no commit touching ${watched[*]} found; cannot test drift" >&2; exit 1; }
old_sha="$(git rev-parse "$watched_tip^")"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "ok   $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL $1"; }
exits() { # name want got
    [ "$3" = "$2" ] && ok "$1" || bad "$1 (exit $3, want $2)"
}
has() { # name file pattern
    grep -q "$3" "$2" && ok "$1" || bad "$1"
}

echo "== open with no existing issue creates a stamped body"
STUB_NUM="" bash "$S" open v0.11.0-pre "$head_sha" > "$W/a.out" 2>&1; exits "open/new" 0 $?
has "candidate stamped on line 1" "$W/capture.md" "^Candidate: v0.11.0-pre ($head_sha)\$"
has "full template in the body" "$W/capture.md" '^## 13. Promote'
has "title drops the -pre suffix" "$STUB_LOG" 'Release v0.11.0'
head -1 "$W/capture.md" | grep -q '^---' && bad "front matter leaked" || ok "front matter stripped"

echo "== open with an existing issue re-stamps it"
printf 'Candidate: v0.11.0-pre (%s)\n\n- [x] one\n' "$old_sha" > "$W/body.md"
STUB_NUM=42 STUB_BODY="$W/body.md" bash "$S" open v0.11.0-pre2 "$head_sha" >/dev/null 2>&1; exits "open/existing" 0 $?
has "re-stamped to the new candidate" "$W/capture.md" "^Candidate: v0.11.0-pre2 ($head_sha)\$"
has "commented that the candidate moved" "$STUB_LOG" 'issue comment 42'

echo "== verify fails closed with no issue"
STUB_NUM="" bash "$S" verify v0.11.0 "$head_sha" > "$W/c.out" 2>&1; exits "verify/no issue" 1 $?
has "says how to fix it" "$W/c.out" 'Push a pre-release tag'

echo "== verify counts unchecked boxes"
printf 'Candidate: v0.11.0-pre (%s)\n\n- [x] done\n- [ ] not done\n' "$head_sha" > "$W/body.md"
STUB_NUM=42 STUB_BODY="$W/body.md" bash "$S" verify v0.11.0 "$head_sha" > "$W/d.out" 2>&1; exits "verify/unchecked" 1 $?
has "counts them" "$W/d.out" '1 unchecked item'

echo "== verify passes when complete and current"
printf 'Candidate: v0.11.0-pre (%s)\n\n- [x] done\n' "$head_sha" > "$W/body.md"
STUB_NUM=42 STUB_BODY="$W/body.md" bash "$S" verify v0.11.0 "$head_sha" > "$W/e.out" 2>&1; exits "verify/complete" 0 $?

echo "== verify rejects a stale candidate unless overridden"
printf 'Candidate: v0.11.0-pre (%s)\n\n- [x] done\n' "$old_sha" > "$W/body.md"
STUB_NUM=42 STUB_BODY="$W/body.md" STUB_LABELS="release" \
    bash "$S" verify v0.11.0 "$head_sha" > "$W/f.out" 2>&1; exits "verify/stale" 1 $?
has "names the reason" "$W/f.out" 'source changed since the verified build'
STUB_NUM=42 STUB_BODY="$W/body.md" STUB_LABELS=$'release\nrelease:override' \
    bash "$S" verify v0.11.0 "$head_sha" > "$W/f2.out" 2>&1; exits "verify/stale+override" 0 $?
has "still warns" "$W/f2.out" 'WARNING'

echo "== verify rejects a checklist that names no build"
printf -- '- [x] done\n' > "$W/body.md"
STUB_NUM=42 STUB_BODY="$W/body.md" bash "$S" verify v0.11.0 "$head_sha" > "$W/g.out" 2>&1; exits "verify/no header" 1 $?

echo "== status reports what is left"
printf 'Candidate: v0.11.0-pre (%s)\n\n- [x] done\n- [ ] left\n' "$head_sha" > "$W/body.md"
STUB_NUM=42 STUB_BODY="$W/body.md" bash "$S" status > "$W/s.out" 2>&1; exits "status" 0 $?
has "shows the count" "$W/s.out" '1 item(s) left'
has "shows the candidate" "$W/s.out" "candidate $head_sha"

echo "== close archives the checklist into the release notes"
printf 'Candidate: v0.11.0-pre (%s)\n\n- [x] done\n' "$head_sha" > "$W/body.md"
STUB_NUM=42 STUB_BODY="$W/body.md" bash "$S" close v0.11.0 >/dev/null 2>&1; exits "close" 0 $?
has "keeps the generated notes" "$W/capture.md" 'auto-generated notes'
has "appends the checklist" "$W/capture.md" 'Verification checklist (#42)'

echo
echo "release-checklist test: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
