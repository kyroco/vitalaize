#!/usr/bin/env python3
"""Writes down the last run of macos/uitest/run.sh for docs/mac-app-checks.

    macos/uitest/record.py

It reads macos/build/uitest/out, which the run leaves behind, and writes
docs/mac-app-checks/last-run.md (every step and check, and how it went) and
a smaller copy of every picture under docs/mac-app-checks/pictures.
"""
import datetime
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "macos/build/uitest/out")
DOCS = os.path.join(ROOT, "docs/mac-app-checks")
PICTURES = os.path.join(DOCS, "pictures")

# A throwaway home's path says where this checkout is; the list reads better without it.
HOME = re.compile(r"/[^\s\"]*?/macos/build/uitest/homes/[\w-]+")


def tidy(text):
    return HOME.sub("~", text).replace("|", "\\|")


def rows(path):
    """(passed, words) for each line of a results or checks file."""
    out = []
    for line in open(path, encoding="utf-8").read().splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        passed = parts[0].strip() == "ok"
        # A step's line carries its line number in the steps file first.
        words = parts[2:] if parts[1].strip().isdigit() else parts[1:]
        out.append((passed, " ".join(w for w in words if w)))
    return out


def main():
    if not os.path.isdir(OUT):
        sys.exit("No run to write down: run macos/uitest/run.sh first.")
    shutil.rmtree(PICTURES, ignore_errors=True)
    lines = []
    total = failed = pictures = 0
    for scenario in sorted(os.listdir(OUT)):
        folder = os.path.join(OUT, scenario)
        if not os.path.isdir(folder):
            continue
        lines += ["", f"## {scenario}", ""]
        results = sorted((f for f in os.listdir(folder) if f.endswith(".results.txt")),
                         key=lambda f: os.path.getmtime(os.path.join(folder, f)))
        for name in results:
            steps = rows(os.path.join(folder, name))
            bad = [s for s in steps if not s[0]]
            total += len(steps)
            failed += len(bad)
            lines += [f"### {name[:-len('.results.txt')]}: {len(steps) - len(bad)} of {len(steps)} steps passed", "", "```"]
            lines += [("ok    " if ok else "FAIL  ") + tidy(words) for ok, words in steps]
            lines += ["```", ""]
        checks = os.path.join(folder, "checks.txt")
        if os.path.exists(checks):
            found = rows(checks)
            total += len(found)
            failed += len([c for c in found if not c[0]])
            lines += ["### Checked from outside the app", ""]
            lines += [f"- {'ok' if ok else 'FAIL'}: {tidy(words)}" for ok, words in found]
            lines += [""]
        os.makedirs(os.path.join(PICTURES, scenario), exist_ok=True)
        for name in sorted(f for f in os.listdir(folder) if f.endswith(".png")):
            target = os.path.join(PICTURES, scenario, name[:-4] + ".jpg")
            subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "60", "--resampleWidth", "1000",
                            os.path.join(folder, name), "--out", target], capture_output=True, check=True)
            pictures += 1

    when = datetime.datetime.now().strftime("%B %-d, %Y")
    head = [
        "# The Mac app's last full run",
        "",
        f"Written by `macos/uitest/record.py` from the run of `macos/uitest/run.sh --all` on {when}.",
        "Do not edit it by hand: run the script again.",
        "",
        f"{total - failed} of {total} steps and checks passed. {pictures} pictures are in `pictures/`, one folder for each scenario.",
        "",
        "A step is one line of a file in `macos/uitest/steps/`: `click`, `type`, `toggle` and `press` use a control,",
        "`wait`, `expect`, `absent`, `value`, `enabled` and `disabled` look at the screen, `opened` checks what the app",
        "asked macOS to open, and `snap` takes the picture of that name. The list of screens and controls these",
        "belong to is in [../mac-app-checks.md](../mac-app-checks.md).",
    ]
    os.makedirs(DOCS, exist_ok=True)
    with open(os.path.join(DOCS, "last-run.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(head + lines).rstrip() + "\n")
    print(f"{total - failed} of {total} passed, {pictures} pictures. Written to {DOCS}.")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
