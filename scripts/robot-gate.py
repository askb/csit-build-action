#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""Fail a CSIT run whose robot pass rate is below the Jenkins thresholds.

builder's run scripts end the robot call with ``|| true``: on Jenkins the
build result comes from the Robot plugin parsing ``output.xml`` against
robot-pass-threshold / robot-unstable-threshold, not from the shell exit
code. GHA has no such plugin, so apply the same thresholds here. Without
this, a run in which every test fails still reports success.

Usage: robot-gate.py <output.xml> [pass-threshold] [unstable-threshold]
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET


def main() -> int:
    """Compare the robot pass rate against the configured thresholds."""
    path = sys.argv[1]
    pass_thr = float(sys.argv[2]) if len(sys.argv) > 2 else 100.0
    unstable_thr = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0

    try:
        stat = ET.parse(path).getroot().find("./statistics/total/stat")
    except (OSError, ET.ParseError) as exc:
        print(f"ROBOT GATE: cannot read {path}: {exc}", file=sys.stderr)
        return 1
    if stat is None:
        print(f"ROBOT GATE: no statistics in {path}", file=sys.stderr)
        return 1

    passed = int(stat.get("pass", 0))
    failed = int(stat.get("fail", 0))
    total = passed + failed
    pct = 100.0 * passed / total if total else 0.0
    print(f"ROBOT GATE: {passed}/{total} passed ({pct:.2f}%)")

    if pct < pass_thr:
        print(
            f"ROBOT GATE: FAILED, {pct:.2f}% < pass threshold {pass_thr}%",
            file=sys.stderr,
        )
        return 1
    if pct < unstable_thr:
        print(f"ROBOT GATE: unstable, {pct:.2f}% < {unstable_thr}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
