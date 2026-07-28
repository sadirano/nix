#!/usr/bin/env bash
#
# The release checklist lives in a GitHub issue, not in the tree.
#
# It used to be RELEASE-CHECKLIST.md, which had two problems: ticking it cost
# six commits of `docs: check off sections 11-13`, and the file was deleted
# once v0.10.0 shipped (per its own last step), leaving a gate that treated a
# missing file as a pass. The whole manual verification surface - PATH and
# registry mutation, pickers, the clipboard, the Scoop channels - was behind
# that pass.
#
# Now:
#   open   <tag> <sha>   a pre-release tag opens (or re-stamps) the issue
#   verify <tag> <sha>   a stable tag refuses to publish unless it is complete
#   close  <tag>         after publishing, archive it into the release notes
#   selftest             exercise the parsing on fixtures, no network
#
# verify is FAIL-CLOSED: no issue means no release.

set -euo pipefail

TEMPLATE=".github/ISSUE_TEMPLATE/release-checklist.md"
LABEL="release"
OVERRIDE_LABEL="release:override"

die() { printf '::error::%s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# ---- text helpers (selftested below) ----------------------------------------

# versionOf strips a pre-release suffix, so every candidate for a version and
# the stable tag itself resolve to ONE issue: v0.11.0-pre3 -> v0.11.0.
versionOf() { printf '%s' "${1%%-*}"; }

# uncheckedLines lists the boxes still open. Issue bodies come back from the
# API with CRLF, hence the tolerant line end.
uncheckedLines() { grep -n '^- \[ \]' || true; }

# candidateSha reads the commit out of the "Candidate: <tag> (<sha>)" header CI
# stamps. Empty means the checklist never named a build, which is itself a
# failure: a checklist that does not say what it verified proves nothing.
# Kept to ONE process on purpose: `sed | head -1` under `set -o pipefail` fails
# the whole substitution whenever head closes the pipe first.
candidateSha() { sed -n '/^Candidate:/{s/.*(\([0-9a-fA-F]\{7,40\}\)).*/\1/p;q;}'; }

# stripFrontMatter drops the ISSUE_TEMPLATE YAML header, which GitHub's web
# form consumes but an API-created issue would show as literal text. The second
# pass drops the blank lines left behind, so the Candidate: header lands on the
# issue's first line where a reader (and setCandidate) expects it.
stripFrontMatter() {
    sed '1{/^---[[:space:]]*$/!q};1,/^---[[:space:]]*$/d' | sed '/./,$!d'
}

# setCandidate rewrites the header in place, or adds it if a hand-opened issue
# has none.
setCandidate() {
    awk -v line="Candidate: $1 ($2)" '
        !done && /^Candidate:/ { print line; done = 1; next }
        { print }
        END { if (!done) print line }
    '
}

# ---- issue lookup -----------------------------------------------------------

# findIssue prints the number of the release issue for $TITLE, or nothing.
# Matched on the exact title rather than a search query so a stray issue
# mentioning the version cannot stand in for the checklist.
findIssue() {
    gh issue list --label "$LABEL" --state "$1" --limit 100 --json number,title \
        --jq 'map(select(.title == env.TITLE)) | first | .number // empty'
}

ensureLabels() {
    gh label create "$LABEL" --color 1D76DB \
        --description "Release verification checklist" >/dev/null 2>&1 || true
    gh label create "$OVERRIDE_LABEL" --color B60205 \
        --description "Publish despite src/ changes since the verified build" >/dev/null 2>&1 || true
}

# ---- commands ---------------------------------------------------------------

cmdOpen() {
    local tag="$1" sha="$2" num body
    TITLE="Release $(versionOf "$tag")"; export TITLE
    ensureLabels
    num="$(findIssue open)"
    if [ -z "$num" ]; then
        stripFrontMatter < "$TEMPLATE" | setCandidate "$tag" "$sha" > "$tmp"
        num="$(gh issue create --title "$TITLE" --label "$LABEL" --body-file "$tmp" | sed 's#.*/##')"
        note "opened #$num for $TITLE (candidate $tag)"
    else
        gh issue view "$num" --json body --jq .body | setCandidate "$tag" "$sha" > "$tmp"
        gh issue edit "$num" --body-file "$tmp" >/dev/null
        gh issue comment "$num" --body \
"Candidate is now \`$tag\` ($sha).

Verify against that build. Boxes ticked against an earlier candidate only
still hold where the change since it cannot have touched them." >/dev/null
        note "restamped #$num to $tag"
    fi
}

cmdVerify() {
    local tag="$1" head="$2" num body open_boxes sha changed
    TITLE="Release $tag"; export TITLE
    num="$(findIssue all)"
    [ -n "$num" ] || die "no \"$TITLE\" issue labelled \`$LABEL\`. Push a pre-release tag to open one, verify it, then tag $tag."

    body="$(gh issue view "$num" --json body --jq .body)"

    open_boxes="$(printf '%s\n' "$body" | uncheckedLines)"
    if [ -n "$open_boxes" ]; then
        printf '%s\n' "$open_boxes" >&2
        die "#$num has $(printf '%s\n' "$open_boxes" | wc -l | tr -d ' ') unchecked item(s)."
    fi

    sha="$(printf '%s\n' "$body" | candidateSha)"
    [ -n "$sha" ] || die "#$num has no \"Candidate: <tag> (<sha>)\" header, so there is no record of WHICH build was verified."
    git cat-file -e "${sha}^{commit}" 2>/dev/null || die "the candidate commit $sha in #$num is not in this repository."
    git merge-base --is-ancestor "$sha" "$head" ||
        die "the verified build ($sha) is not an ancestor of $tag. The checklist describes a different history."

    # The v0.10.0 cycle verified a pre that was 12 commits stale. A checklist
    # only speaks for the binary it was run against, so source changes since
    # then invalidate it - deliberately hard to ignore, with one explicit way
    # out for a release that changed nothing users run.
    changed="$(git log --oneline "$sha..$head" -- src/ build.zig build.zig.zon)"
    if [ -n "$changed" ]; then
        printf '%s\n' "$changed" >&2
        # Not `gh ... | grep -q`: under pipefail, grep quitting early can leave
        # the pipeline non-zero and silently drop the override.
        local labels
        labels="$(gh issue view "$num" --json labels --jq '.labels[].name')"
        if grep -qx "$OVERRIDE_LABEL" <<<"$labels"; then
            note "WARNING: source changed since the verified build; publishing anyway on the $OVERRIDE_LABEL label."
        else
            die "source changed since the verified build ($sha). Cut a new pre-release and re-verify, or add the \`$OVERRIDE_LABEL\` label to #$num."
        fi
    fi

    note "#$num is complete and verified against $sha."
}

# cmdStatus is the terminal view: what is left on the checklist in flight.
# Wired up as `r nix :checklist`.
cmdStatus() {
    local num title body sha left
    num="$(gh issue list --label "$LABEL" --state open --limit 100 --json number --jq 'first | .number // empty')"
    [ -n "$num" ] || { note "no open release checklist"; return 0; }
    title="$(gh issue view "$num" --json title --jq .title)"
    body="$(gh issue view "$num" --json body --jq .body)"
    sha="$(printf '%s\n' "$body" | candidateSha)"
    note "#$num $title (candidate ${sha:-unstamped})"
    left="$(printf '%s\n' "$body" | uncheckedLines)"
    if [ -z "$left" ]; then
        note "complete - the stable tag will publish."
    else
        note "$(printf '%s\n' "$left" | wc -l | tr -d ' ') item(s) left:"
        printf '%s\n' "$left"
    fi
}

cmdClose() {
    local tag="$1" num body notes
    TITLE="Release $tag"; export TITLE
    num="$(findIssue all)"
    [ -n "$num" ] || { note "no checklist issue to close"; return 0; }

    body="$(gh issue view "$num" --json body --jq .body)"
    notes="$(gh release view "$tag" --json body --jq .body)"
    # The evidence outlives the issue: an issue body can be edited afterwards,
    # release notes are what the tag shipped with.
    {
        printf '%s\n\n---\n\n' "$notes"
        printf '<details><summary>Verification checklist (#%s)</summary>\n\n' "$num"
        printf '%s\n\n</details>\n' "$body"
    } > "$tmp"
    gh release edit "$tag" --notes-file "$tmp" >/dev/null
    gh issue close "$num" --comment \
"Published as [$tag](https://github.com/${GITHUB_REPOSITORY:-sadirano/nix}/releases/tag/$tag). The completed checklist is archived in the release notes." >/dev/null
    note "closed #$num"
}

# ---- selftest ---------------------------------------------------------------
#
# The parsing here only ever runs during a release, which is the worst possible
# time to discover it wrong, so `zig build ci` runs this on every change.

cmdSelftest() {
    local got want body

    got="$(versionOf v0.11.0-pre3)"; want="v0.11.0"
    [ "$got" = "$want" ] || die "versionOf: got $got want $want"
    got="$(versionOf v0.11.0)"; want="v0.11.0"
    [ "$got" = "$want" ] || die "versionOf: got $got want $want"

    body="$(printf 'Candidate: v0.11.0-pre (abc1234)\n\n- [x] done\n- [ ] not done\r\n- [ ] also not\n')"
    got="$(printf '%s\n' "$body" | uncheckedLines | wc -l | tr -d ' ')"
    [ "$got" = "2" ] || die "uncheckedLines: got $got want 2"
    got="$(printf '%s\n' "$body" | candidateSha)"
    [ "$got" = "abc1234" ] || die "candidateSha: got $got want abc1234"

    got="$(printf -- '- [x] all done\n' | uncheckedLines | wc -l | tr -d ' ')"
    [ "$got" = "0" ] || die "uncheckedLines on a complete list: got $got want 0"

    got="$(printf 'no header here\n' | candidateSha)"
    [ -z "$got" ] || die "candidateSha with no header: got $got want empty"

    got="$(printf '%s\n' "$body" | setCandidate v0.11.0-pre3 deadbee | head -1)"
    [ "$got" = "Candidate: v0.11.0-pre3 (deadbee)" ] || die "setCandidate: got $got"
    got="$(printf 'no header\n' | setCandidate v0.1.0 abc1234 | tail -1)"
    [ "$got" = "Candidate: v0.1.0 (abc1234)" ] || die "setCandidate (absent): got $got"

    [ -f "$TEMPLATE" ] || die "$TEMPLATE is missing: the flow has no checklist to open."
    got="$(stripFrontMatter < "$TEMPLATE" | head -1)"
    [ "$got" != "---" ] || die "stripFrontMatter left the YAML header in place"
    got="$(stripFrontMatter < "$TEMPLATE" | candidateSha)"
    [ -z "$got" ] || die "the template must not ship a real candidate sha"
    local template_body
    template_body="$(stripFrontMatter < "$TEMPLATE")"
    grep -q '^Candidate:' <<<"$template_body" ||
        die "the template has no Candidate: header for CI to stamp"
    grep -q '^- \[ \]' <<<"$template_body" ||
        die "the template has no unchecked boxes, so the gate would pass on an untouched copy"

    note "release-checklist selftest: ok"
}

# ---- entry point ------------------------------------------------------------

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

case "${1:-}" in
    open)     cmdOpen "${2:?tag}" "${3:?sha}" ;;
    verify)   cmdVerify "${2:?tag}" "${3:?sha}" ;;
    close)    cmdClose "${2:?tag}" ;;
    status)   cmdStatus ;;
    selftest) cmdSelftest ;;
    *) die "usage: release-checklist.sh open|verify|close <tag> [sha] | status | selftest" ;;
esac
