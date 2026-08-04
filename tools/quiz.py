#!/usr/bin/env python3
"""A free-recall quiz over 100 situations, to measure which nix features come
to mind unprompted.

BRANCH-ONLY, alongside src/telemetry.zig.

    python tools/quiz.py                 # next 20 unanswered, shuffled
    python tools/quiz.py --count 100     # the lot
    python tools/quiz.py --only weighed  # just the features under review
    python tools/quiz.py --score         # where you are, no questions
    python tools/quiz.py --debrief       # answers + what nix offers
    python tools/quiz.py --reset

Answers are free text on purpose. Multiple choice would name the feature and
teach it mid-quiz, which is exactly the thing being measured. Nothing is
revealed until --debrief, for the same reason.

Type the command you would actually run. `?` means "no idea", `-` means "I
would not use nix for this" - both are real answers and are recorded as such.
"""

import argparse
import json
import os
import random
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quiz_bank import Q  # noqa: E402

HOME = os.environ.get("NIX_HOME") or str(Path.home() / ".nix")
STORE = Path(HOME) / "quiz-answers.json"

# Weighting: the point is the features whose worth is in question. o/x/g/f/p
# are known-used and are here only as calibration, so a run does not open with
# five questions whose answers prove nothing.
WEIGHT = {"weighed": 1.0, "obscure": 1.0, "cannot": 0.9,
          "ambiguous": 0.5, "not-first": 0.5, "nix-core": 0.3}

BAR = "-" * 66


def load():
    if STORE.exists():
        try:
            return json.loads(STORE.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass
    return {"answers": {}, "started": datetime.now().isoformat(timespec="seconds")}


def save(state):
    STORE.parent.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(state, indent=1), encoding="utf-8")


def pick(state, count, only):
    pool = [q for q in Q if str(q["id"]) not in state["answers"]]
    if only:
        pool = [q for q in pool if q["kind"] in only]
    random.shuffle(pool)
    # Order within the batch stays shuffled; the WEIGHT only decides how likely
    # a low-value question is to be in it at all.
    keep = [q for q in pool if random.random() <= WEIGHT.get(q["kind"], 1.0)]
    keep += [q for q in pool if q not in keep]
    return keep[:count]


def ask(state, count, only):
    batch = pick(state, count, only)
    if not batch:
        print("nothing left unanswered - `--score` for where you are, "
              "`--debrief` for the answers")
        return
    done = len(state["answers"])
    print(f"\n{len(batch)} situations. {done}/{len(Q)} answered so far.")
    print("Type what you would actually run.  ?  = no idea   "
          "-  = not a nix job   q = stop\n")
    for i, q in enumerate(batch, 1):
        print(BAR)
        print(f"[{i}/{len(batch)}]  #{q['id']}")
        print()
        for line in wrap(q["s"], 66):
            print("  " + line)
        print()
        try:
            a = input("  > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nstopped - answers so far are saved")
            break
        if a.lower() in ("q", "quit", "exit"):
            print("stopped - answers so far are saved")
            break
        state["answers"][str(q["id"])] = {
            "a": a, "at": datetime.now().isoformat(timespec="seconds")}
        save(state)
    save(state)
    print(BAR)
    print(f"saved -> {STORE}")
    score(state, brief=True)


def wrap(text, width):
    out, line = [], ""
    for word in text.split():
        if len(line) + len(word) + 1 > width:
            out.append(line)
            line = word
        else:
            line = f"{line} {word}".strip()
    if line:
        out.append(line)
    return out


def classify(ans):
    a = (ans or "").strip().lower()
    if not a:
        return "blank"
    if a in ("?", "??", "idk", "no idea", "dunno"):
        return "unknown"
    if a in ("-", "n/a", "na", "not nix"):
        return "not-nix"
    return "answered"


def score(state, brief=False):
    ans = state["answers"]
    if not ans:
        print("no answers yet")
        return
    by_kind = defaultdict(Counter)
    for q in Q:
        r = ans.get(str(q["id"]))
        if not r:
            continue
        by_kind[q["kind"]][classify(r["a"])] += 1

    print(f"\n{len(ans)}/{len(Q)} answered\n")
    print(f"  {'category':<12} {'answered':>8} {'no idea':>8} {'not nix':>8}")
    for kind in ("weighed", "obscure", "cannot", "ambiguous", "not-first", "nix-core"):
        c = by_kind.get(kind)
        if not c:
            continue
        print(f"  {kind:<12} {c['answered']:>8} {c['unknown']:>8} {c['not-nix']:>8}")

    if brief:
        return

    # Per-feature recall: for each tag, how many of its situations produced an
    # answer at all. This is the number the cut decision reads.
    # Only questions actually PUT count: an unasked feature has not failed
    # recall, and mixing the two would read as a verdict nobody earned.
    tag_total, tag_hit, tag_left = Counter(), Counter(), Counter()
    for q in Q:
        r = ans.get(str(q["id"]))
        for t in q["tags"]:
            if not r:
                tag_left[t] += 1
                continue
            tag_total[t] += 1
            if classify(r["a"]) == "answered":
                tag_hit[t] += 1
    print("\n  recall by feature (answered / asked, and still to ask)\n")
    for t, n in sorted(tag_total.items(), key=lambda kv: (tag_hit[kv[0]] / kv[1], -kv[1])):
        got = tag_hit[t]
        mark = "  " if got == n else ("!!" if got == 0 else " ~")
        left = f"   ({tag_left[t]} still to ask)" if tag_left[t] else ""
        print(f"  {mark} {t:<12} {got}/{n}{left}")
    unasked = sorted(t for t in tag_left if t not in tag_total)
    if unasked:
        print("\n  not asked about yet: " + ", ".join(unasked))
    print("\n  !! nothing came to mind for any of its situations so far")


def debrief(state):
    ans = state["answers"]
    shown = 0
    for q in Q:
        r = ans.get(str(q["id"]))
        if not r:
            continue
        shown += 1
        print(BAR)
        print(f"#{q['id']}  [{q['kind']}]")
        for line in wrap(q["s"], 66):
            print("  " + line)
        print(f"\n  you said: {r['a'] or '(blank)'}")
        for line in wrap("nix: " + q["note"], 66):
            print("  " + line)
        print()
    if not shown:
        print("nothing answered yet")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=20)
    ap.add_argument("--only", nargs="*", default=None,
                    help="kinds: weighed obscure cannot ambiguous not-first")
    ap.add_argument("--score", action="store_true")
    ap.add_argument("--debrief", action="store_true")
    ap.add_argument("--reset", action="store_true")
    args = ap.parse_args()

    if args.reset:
        if STORE.exists():
            STORE.unlink()
        print("cleared")
        return
    state = load()
    if args.score:
        score(state)
    elif args.debrief:
        debrief(state)
    else:
        ask(state, args.count, args.only)


if __name__ == "__main__":
    main()
