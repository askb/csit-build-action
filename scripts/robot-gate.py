#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""Report and gate CSIT robot results.

Gate (default), run once per CSIT job::

    robot-gate.py <output.xml> [pass-threshold] [unstable-threshold]

builder's run scripts end the robot call with ``|| true``: on Jenkins the
build result comes from the Robot plugin parsing ``output.xml`` against
robot-pass-threshold / robot-unstable-threshold, not from the shell exit
code. GHA has no such plugin, so apply the same thresholds here. Without
this, a run in which every test fails still reports success.

Summary, run once per fan-out::

    robot-gate.py --summary <artifacts-dir> [expected-jobs-file] \
        [--html <dir>] [--title <text>]

Renders the go/no-go table across every job. A job listed in
expected-jobs-file that produced no ``output.xml`` is an error row, never
dropped: a silently missing job would make the report untrustworthy.

``--html`` also publishes a landing page, ``report.json``, the markdown and
each job's own Robot report and log into <dir>.

Both modes append markdown to ``$GITHUB_STEP_SUMMARY`` when set.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from itertools import dropwhile
from pathlib import Path

# The site renderer sits beside this script, first on sys.path: no packaging.
from csit_site import (
    created_top,
    html_overlaps_job,
    job_list,
    linked,
    md_cell,
    md_row,
    unsafe_links,
    write_replacing,
    write_site,
)

# A wall of failures helps nobody, and GitHub truncates a step summary at
# 1 MiB. Enough to see the pattern, the artifact has the rest.
MAX_FAILED_LISTED = 25

# A summary over GitHub's 1 MiB limit is cut mid-table, untrustworthy just
# when a job is big; at ~40 bytes a row this stays well clear of it.
MAX_TESTS_LISTED = 2000

STATUS_MARK = {"PASS": "\u2705", "FAIL": "\u274c", "SKIP": "\u23ed\ufe0f"}


def emit(text: str) -> None:
    """Append markdown to the GHA run summary, echoing it when run locally."""
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")
    else:
        print(text)


def walk_suites(elem, prefix=""):
    """Yield (dotted suite name, [(test name, status)]) for every suite.

    Robot nests suites arbitrarily and ElementTree has no parent links, so the
    dotted path is carried down rather than reconstructed. A suite with no
    tests at all is still yielded: an empty suite is a result worth seeing.
    """
    for suite in elem.findall("suite"):
        name = suite.get("name") or "?"
        path = f"{prefix}.{name}" if prefix else name
        tests = []
        for test in suite.findall("test"):
            status = test.find("status")
            tests.append(
                (
                    test.get("name") or "(unnamed)",
                    status.get("status", "?") if status is not None else "?",
                )
            )
        if tests or not suite.findall("suite"):
            yield path, tests
        yield from walk_suites(suite, path)


def read_results(path, detail=False):
    """Return a result dict for one robot run.

    Raises OSError, ET.ParseError or ValueError if the file is unusable, so
    an unreadable result is never mistaken for a passing one.

    `detail` additionally walks every suite and test. The cross-job summary
    reads 100+ files and only needs the totals, so it does not pay for that.
    """
    root = ET.parse(path).getroot()
    # Robot Framework before 4 lists Critical Tests ahead of All Tests; the
    # verdict must count every test, so it takes All Tests by name and
    # never stands in another total for it.
    stat = next(
        (
            s
            for s in root.findall("./statistics/total/stat")
            if (s.text or "").strip() == "All Tests"
        ),
        None,
    )
    if stat is None:
        raise ValueError("no All Tests total in <statistics><total>")

    passed = int(stat.get("pass", 0))
    # Pass rate stays passed/(passed+failed), as the Jenkins Robot plugin
    # thresholds were tuned on; skips are reported but kept out of the verdict.
    total = passed + int(stat.get("fail", 0))

    failed = []
    for test in root.iter("test"):
        status = test.find("status")
        if status is not None and status.get("status") == "FAIL":
            failed.append(test.get("name") or "(unnamed)")

    # Robot names the run on the top <suite>; the <robot> root carries none.
    top = root.find("./suite")
    result = {
        "name": (top.get("name") if top is not None else None) or "robot",
        "passed": passed,
        "total": total,
        "pct": 100.0 * passed / total if total else 0.0,
        "skipped": int(stat.get("skip", 0)),
        "failed": failed,
        "suites": list(walk_suites(root)) if detail else [],
    }
    return result


def suite_table(suites):
    """One row per robot suite, so every test in the run is accounted for."""
    rows = [
        "| Suite | Tests | \u2705 | \u274c | \u23ed\ufe0f | Pass rate |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for path, tests in suites:
        passed = sum(1 for _, st in tests if st == "PASS")
        failed = sum(1 for _, st in tests if st == "FAIL")
        skipped = sum(1 for _, st in tests if st == "SKIP")
        denom = passed + failed
        rate = f"{100.0 * passed / denom:.2f}%" if denom else "\u2013"
        name = md_cell(path)
        rows.append(
            f"| {name} | {len(tests)} | {passed} | {failed} | {skipped} | {rate} |"
        )
    return rows


def test_list(suites):
    """Every test name with its status, collapsed by default.

    The suite table above says how many; a release discussion regularly needs
    to know exactly which. log.html in the artifact is the richer view, but it
    costs a download -- this is the same information one click away.
    """
    total = sum(len(tests) for _, tests in suites)
    lines = [f"<details><summary>All {total} tests</summary>", ""]
    shown = 0
    for path, tests in suites:
        if not tests:
            continue
        if shown >= MAX_TESTS_LISTED:
            break
        lines += [f"**{path}**", ""]
        for name, status in tests:
            if shown >= MAX_TESTS_LISTED:
                break
            lines.append(f"- {STATUS_MARK.get(status, status)} {name}")
            shown += 1
        lines.append("")
    if shown < total:
        lines += [f"... and {total - shown} more, see `log.html`.", ""]
    lines.append("</details>")
    return lines


def gate(argv):
    """Report one job's result and apply the Jenkins pass/unstable thresholds."""
    path = argv[0]
    pass_thr = float(argv[1]) if len(argv) > 1 else 100.0
    unstable_thr = float(argv[2]) if len(argv) > 2 else 0.0

    try:
        res = read_results(path, detail=True)
    except (OSError, ET.ParseError, ValueError) as exc:
        print(f"ROBOT GATE: cannot read {path}: {exc}", file=sys.stderr)
        emit(f"### \u274c No robot results\n\n`{path}`: {exc}")
        return 1

    passed, total, pct = res["passed"], res["total"], res["pct"]
    failed = res["failed"]
    print(f"ROBOT GATE: {passed}/{total} passed ({pct:.2f}%)")
    # No passed or failed tests is never a pass, whatever the threshold.
    ok = total > 0 and pct >= pass_thr
    # Report mode reads this back so the fan-out table agrees with the job.
    write_replacing(
        Path(path).with_name(GATE_FILE),
        json.dumps({"pass_threshold": pass_thr, "ok": ok}) + "\n",
    )
    mark = "\u2705" if ok else "\u274c"
    job = os.environ.get("CSIT_JOB") or res["name"]
    skipped = f", {res['skipped']} skipped" if res["skipped"] else ""
    lines = [
        f"### {mark} {job} \u2014 {passed}/{total} passed ({pct:.2f}%){skipped}",
        "",
    ]

    reason = (
        "no tests passed or failed"
        if total == 0
        else f"{pct:.2f}% < pass threshold {pass_thr}%"
    )
    if not ok:
        lines += [f"Failed: {reason}.", ""]
    elif pct < unstable_thr:
        lines += [f"\u26a0\ufe0f Unstable: below {unstable_thr}%.", ""]

    lines += suite_table(res["suites"]) + [""]

    if failed:
        shown = failed[:MAX_FAILED_LISTED]
        plural = "s" if len(failed) != 1 else ""
        lines += [f"<details><summary>{len(failed)} failed test{plural}</summary>", ""]
        lines.extend(f"- {name}" for name in shown)
        if len(failed) > len(shown):
            lines.append(f"- ... and {len(failed) - len(shown)} more")
        lines += ["", "</details>", ""]

    lines += test_list(res["suites"])

    emit("\n".join(lines))

    if not ok:
        print(
            f"ROBOT GATE: FAILED, {reason}",
            file=sys.stderr,
        )
        return 1
    if pct < unstable_thr:
        print(f"ROBOT GATE: unstable, {pct:.2f}% < {unstable_thr}%")
    return 0


GATE_FILE = "robot-gate.json"


def job_threshold(job_dir: Path) -> float:
    """Pass threshold the job's own gate applied; 100% when it left none.

    A linked threshold file is ignored, so outside metadata cannot turn a
    failing job green.
    """
    if linked(job_dir / GATE_FILE):
        return 100.0
    try:
        data = json.loads((job_dir / GATE_FILE).read_text(encoding="utf-8"))
        return float(data["pass_threshold"])
    except (OSError, ValueError, KeyError, TypeError):
        return 100.0


def summarise(argv, html_dir="", title=""):
    """Render the cross-job go/no-go table from downloaded job artifacts."""
    root = Path(argv[0])
    if ".." in dropwhile("..".__eq__, Path(html_dir).parts):
        # A missing component before `..` would hide a linked destination
        # from the checks below; a leading `..` is the cwd's real parent.
        print(f"ROBOT GATE: --html {html_dir} has '..' after a name", file=sys.stderr)
        return 2
    new_top = created_top(root, Path(html_dir)) if html_dir else None
    if html_dir and html_overlaps_job(root, Path(html_dir)):
        # A site in a job's directory would mix with, and mark, its results.
        print(
            f"ROBOT GATE: --html {html_dir} overlaps a job directory; "
            "publish the site elsewhere",
            file=sys.stderr,
        )
        return 2
    links = unsafe_links(Path(html_dir)) if html_dir else []
    if links:
        print(
            f"ROBOT GATE: --html {html_dir} holds {len(links)} symlink(s), e.g. "
            f"{links[0]}, that a Pages upload would follow; publish elsewhere",
            file=sys.stderr,
        )
        return 2
    try:
        expected = job_list(root, argv[1] if len(argv) > 1 else "")
    except ValueError as err:
        print(f"ROBOT GATE: {err}", file=sys.stderr)
        return 2

    rows = []
    for name in expected:
        xml = root / name / "output.xml"
        try:
            # Results reached through a link are not this job's own.
            if linked(xml):
                raise OSError(f"{xml} is reached through a symlink")
            res = read_results(xml)
        except (OSError, ET.ParseError, ValueError):
            # No results at all: the job died before or during robot. That is
            # worse than a test failure, so it must never be omitted.
            rows.append({"job": name, "state": "missing"})
            continue
        rows.append(
            {
                "job": name,
                "state": (
                    "pass"
                    if res["total"] > 0 and res["pct"] >= job_threshold(root / name)
                    else "fail"
                ),
                "passed": res["passed"],
                "total": res["total"],
                "pct": res["pct"],
                "skipped": res["skipped"],
            }
        )

    counts = Counter(r["state"] for r in rows)
    good, total_jobs = counts["pass"], len(rows)
    if total_jobs == 0:
        # Zero of zero is not success. Never let an empty run render green.
        lines = [
            "## CSIT results \u2014 \u26a0\ufe0f no jobs to report",
            "",
            f"Nothing was dispatched, or no results reached `{root}`.",
        ]
    else:
        verdict = "\u2705 all green" if good == total_jobs else "\u274c not all green"
        lines = [
            f"## CSIT results \u2014 {good}/{total_jobs} jobs green ({verdict})",
            "",
            "| Job | Tests | Pass rate | Result |",
            "| --- | --- | --- | --- |",
            *(md_row(r) for r in rows),
            "",
        ]
        if counts["fail"] or counts["missing"]:
            lines.append(
                f"{counts['fail']} job(s) had test failures, "
                f"{counts['missing']} produced no results. Download a job's "
                "artifact for `log.html` / `report.html`."
            )
    emit("\n".join(lines))

    # Also as a file; html-dir first, so one at csit-summary.md stays a dir.
    md = "\n".join(lines) + "\n"
    out = Path(html_dir or ".")
    out.mkdir(parents=True, exist_ok=True)
    local = Path("csit-summary.md")
    a_job = root.resolve() == Path.cwd() and local.name in {r["job"] for r in rows}
    if local.is_dir() or (local.is_symlink() and a_job):
        # A job so named under results-dir `.` is kept; the summary has it.
        print(f"ROBOT GATE: {local} is a job dir or link; kept", file=sys.stderr)
    else:
        write_replacing(local, md)
    if html_dir:
        write_replacing(out / "csit-summary.md", md)
        write_site(out, rows, title, good, total_jobs, root, new_top)
    print(f"ROBOT SUMMARY: {good}/{total_jobs} jobs green")
    return 0


def main():
    """Dispatch to the gate or the summary renderer."""
    argv = sys.argv[1:]
    if argv and argv[0] == "--summary":
        parser = argparse.ArgumentParser(prog="robot-gate.py --summary")
        parser.add_argument("results")
        parser.add_argument("expected", nargs="?", default="")
        parser.add_argument("--html", default="", help="publish a site here")
        parser.add_argument("--title", default="", help="heading for the site")
        args = parser.parse_args(argv[1:])
        return summarise([args.results, args.expected], args.html, args.title)
    return gate(argv)


if __name__ == "__main__":
    raise SystemExit(main())
