#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""Report and gate CSIT robot results.

Two modes, one parser.

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

Renders the go/no-go table across every job. Whether an ODL release ships is
a community decision, so the table has to be readable and it has to be
complete: a job listed in expected-jobs-file that produced no ``output.xml``
is reported as an error row, never dropped. A silently missing job is the
one bug that would make the whole report untrustworthy.

``--html`` additionally publishes a landing page, ``report.json`` and the
markdown into <dir>, alongside whatever ``rebot`` put there. rebot renders the
drill-down and is not reimplemented; this page exists for the one thing rebot
cannot show, a job that produced no ``output.xml`` at all.

Both modes append markdown to ``$GITHUB_STEP_SUMMARY`` when set.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone
from html import escape
from urllib.parse import quote
from pathlib import Path

# A wall of failures helps nobody, and GitHub truncates a step summary at
# 1 MiB. Enough to see the pattern, the artifact has the rest.
MAX_FAILED_LISTED = 25

# Every test is named in the per-job report, but a summary that overruns
# GitHub's 1 MiB limit is silently truncated mid-table -- which would make the
# report untrustworthy exactly when a job is big enough to matter. At ~40
# bytes a row this stays an order of magnitude clear of the limit.
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
    stat = root.find("./statistics/total/stat")
    if stat is None:
        raise ValueError("no <statistics><total> element")

    passed = int(stat.get("pass", 0))
    # Pass rate stays passed/(passed+failed), matching the Jenkins Robot
    # plugin thresholds these jobs were tuned against. Skips are reported but
    # deliberately kept out of the verdict: changing that silently would move
    # every job's gate.
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
        rows.append(
            f"| {path} | {len(tests)} | {passed} | {failed} | {skipped} | {rate} |"
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
    ok = pct >= pass_thr
    mark = "\u2705" if ok else "\u274c"
    job = os.environ.get("CSIT_JOB") or res["name"]
    skipped = f", {res['skipped']} skipped" if res["skipped"] else ""
    lines = [
        f"### {mark} {job} \u2014 {passed}/{total} passed "
        f"({pct:.2f}%){skipped}",
        "",
    ]

    if not ok:
        lines += [f"Pass threshold is {pass_thr}%.", ""]
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
            f"ROBOT GATE: FAILED, {pct:.2f}% < pass threshold {pass_thr}%",
            file=sys.stderr,
        )
        return 1
    if pct < unstable_thr:
        print(f"ROBOT GATE: unstable, {pct:.2f}% < {unstable_thr}%")
    return 0


MD_STATE = {"pass": "\u2705", "fail": "\u274c", "missing": "\u26a0\ufe0f no results"}


def md_row(r):
    """One markdown row, with a job that produced nothing still present."""
    if r["state"] == "missing":
        return f"| {r['job']} | \u2013 | \u2013 | {MD_STATE['missing']} |"
    return (
        f"| {r['job']} | {r['passed']}/{r['total']} | "
        f"{r['pct']:.2f}% | {MD_STATE[r['state']]} |"
    )


# Same visual language as lfreleng-actions/github-security-report-action, so an
# LF release page looks like the other LF report pages. Inlined rather than
# templated: one page, no jinja, no CDN -- a release gate should not depend on
# a third-party asset loading.
SITE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CSIT report: {title}</title>
<style>
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif;
  line-height: 1.6; color: #1a202c; background: #f7fafc; padding: 2rem 1rem; }}
.container {{ max-width: 1100px; margin: 0 auto; }}
header {{ background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: #fff; border-radius: 12px; padding: 2rem; margin-bottom: 2rem; }}
header h1 {{ font-size: 2rem; }}
header .meta {{ opacity: 0.9; font-size: 0.9rem; margin-top: 0.5rem; }}
header a {{ color: #fff; }}
section {{ background: #fff; border-radius: 12px; padding: 1.5rem 2rem; margin-bottom: 1.5rem;
  box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
section h2 {{ color: #2d3748; border-bottom: 2px solid #e2e8f0; padding-bottom: 0.5rem; }}
.verdict {{ font-size: 1.5rem; font-weight: 600; margin: 0.5rem 0; }}
.verdict.go {{ color: #2f855a; }}
.verdict.nogo {{ color: #c53030; }}
table {{ width: 100%; border-collapse: collapse; margin-top: 1rem; }}
th, td {{ padding: 0.5rem 0.75rem; text-align: left; border-bottom: 1px solid #edf2f7; }}
th {{ background: #f7fafc; }}
td.num, th.num {{ text-align: right; font-variant-numeric: tabular-nums; }}
tr.fail td:first-child, tr.missing td:first-child {{ font-weight: 600; }}
tr.missing {{ background: #fffaf0; }}
.btn {{ display: inline-block; background: #667eea; color: #fff; padding: 0.5rem 1rem;
  border-radius: 6px; text-decoration: none; font-weight: 500; margin-right: 0.5rem; }}
.btn:hover {{ background: #5568d3; }}
.note {{ color: #718096; font-size: 0.85rem; margin-top: 0.75rem; font-style: italic; }}
footer {{ text-align: center; color: #718096; padding: 2rem; font-size: 0.85rem; }}
</style>
</head>
<body>
<div class="container">
<header>
<h1><span aria-hidden="true">\U0001f9ea</span> CSIT report: {title}</h1>
<div class="meta">Generated {when}{run}</div>
</header>
<section>
<h2>Release gate</h2>
<p class="verdict {cls}">{verdict}</p>
<p class="note">Whether a release ships is a community decision. This page is
the evidence, not the decision: a job that produced no results at all is listed
as such, never omitted.</p>
<p style="margin-top:1rem">{links}</p>
</section>
<section>
<h2>Jobs</h2>
<table>
<thead><tr><th>Job</th><th class="num">Tests</th><th class="num">Pass rate</th>
<th class="num">Skipped</th><th>Result</th><th>Robot</th></tr></thead>
<tbody>
{rows}
</tbody>
</table>
</section>
<footer>Generated by
<a href="https://github.com/lfreleng-actions/csit-build-action">csit-build-action</a>
</footer>
</div>
</body>
</html>
"""

HTML_STATE = {
    "pass": "\u2705 passed",
    "fail": "\u274c failed",
    "missing": "\u26a0\ufe0f no results",
}


def write_site(
    out: Path, rows, title: str, good: int, total_jobs: int, results=None
) -> None:
    """Write the published report: a landing page plus machine-readable JSON.

    Every job already produced Robot's own report.html/log.html, the same
    drill-down ODL reads on Jenkins today, so those are copied in and linked
    per row rather than regenerated. rebot could merge them into one tree, but
    it names each merged suite from the robot suite name and those collide
    across jobs (two suites both called "Openflowplugin", no way to tell which
    job failed) -- unusable for a release gate.

    The table is driven by the dispatched job list, not by whichever files
    arrived, so a job that produced nothing is a visible row, never a gap.
    """
    body = []
    for r in rows:
        # Copied rather than linked to the artifact, so the page still works
        # for anyone, including after the 30-day artifact retention expires.
        drill = ""
        if results is not None:
            names = [
                f
                for f in ("report.html", "log.html")
                if (results / r["job"] / f).is_file()
            ]
            if names:
                (out / r["job"]).mkdir(parents=True, exist_ok=True)
                for f in names:
                    shutil.copy2(results / r["job"] / f, out / r["job"] / f)
                drill = " ".join(
                    f'<a href="{quote(r["job"])}/{f}">{f.split(".")[0]}</a>'
                    for f in names
                )
        cells = (
            ["\u2013", "\u2013", "\u2013"]
            if r["state"] == "missing"
            else [
                f"{r['passed']}/{r['total']}",
                f"{r['pct']:.2f}%",
                str(r["skipped"]),
            ]
        )
        tds = "".join(f'<td class="num">{c}</td>' for c in cells)
        body.append(
            f'<tr class="{r["state"]}"><td>{escape(r["job"])}</td>{tds}'
            f"<td>{HTML_STATE[r['state']]}</td><td>{drill}</td></tr>"
        )

    links = (
        '<a class="btn" href="csit-summary.md">Markdown \u2192</a>'
        '<a class="btn" href="report.json">JSON \u2192</a>'
    )

    server = os.environ.get("GITHUB_SERVER_URL", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    run = (
        f' \u00b7 <a href="{server}/{repo}/actions/runs/{run_id}">run {run_id}</a>'
        if server and repo and run_id
        else ""
    )
    ok = total_jobs and good == total_jobs
    (out / "index.html").write_text(
        SITE.format(
            title=escape(title or "CSIT"),
            when=datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
            run=run,
            cls="go" if ok else "nogo",
            verdict=(
                f"{good}/{total_jobs} jobs green"
                + (" \u2014 all green" if ok else " \u2014 not all green")
                if total_jobs
                else "\u26a0\ufe0f no jobs to report"
            ),
            links=links,
            rows="\n".join(body),
        ),
        encoding="utf-8",
    )
    (out / "report.json").write_text(
        json.dumps(
            {
                "title": title,
                "generated": datetime.now(timezone.utc).isoformat(),
                "run": f"{server}/{repo}/actions/runs/{run_id}" if run_id else "",
                "green": good,
                "jobs": total_jobs,
                "results": rows,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def summarise(argv, html_dir="", title=""):
    """Render the cross-job go/no-go table from downloaded job artifacts."""
    root = Path(argv[0])
    if len(argv) > 1 and argv[1]:
        listed = Path(argv[1]).read_text(encoding="utf-8").splitlines()
        expected = [line.strip() for line in listed if line.strip()]
    elif root.is_dir():
        expected = sorted(p.name for p in root.iterdir() if p.is_dir())
    else:
        # No job list and nothing downloaded. Say so rather than traceback:
        # this renderer exists to make results visible, so it must still
        # produce a readable page when it has none.
        expected = []

    rows = []
    for name in expected:
        try:
            res = read_results(root / name / "output.xml")
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
                    if res["total"] > 0 and res["passed"] == res["total"]
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

    # Same text as a file, so the release discussion can link or paste it.
    md = "\n".join(lines) + "\n"
    Path("csit-summary.md").write_text(md, encoding="utf-8")
    if html_dir:
        out = Path(html_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "csit-summary.md").write_text(md, encoding="utf-8")
        write_site(out, rows, title, good, total_jobs, root)
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
