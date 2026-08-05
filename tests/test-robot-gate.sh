#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check the robot result gate in run-csit.sh.
#
# Jenkins fails a CSIT build when the robot pass rate is under
# robot-pass-threshold (100.0 for every CSIT template). builder's run scripts
# end the robot call with `|| true`, so without this gate a run in which every
# test fails still reports success on GHA.
#
# Usage: tests/test-robot-gate.sh
##############################################################################

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/../scripts/robot-gate.py"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail=0

# $1 name, $2 pass, $3 fail, $4 threshold, $5 expected exit code
check() {
    cat >"${tmp}/output.xml" <<EOF
<robot><statistics><total>
<stat pass="$2" fail="$3">All Tests</stat>
</total></statistics></robot>
EOF
    set +e
    out="$(python3 "${gate}" "${tmp}/output.xml" "$4" 0.0 2>&1)"
    rc=$?
    set -e
    if [ "${rc}" -ne "$5" ]; then
        echo "FAIL: $1: expected exit $5, got ${rc}"
        echo "      ${out}"
        fail=1
    else
        echo "ok: $1 (exit ${rc})"
    fi
}

check "all passed" 9 0 100.0 0
check "one failed" 8 1 100.0 1
check "all failed" 0 26 100.0 1
check "l2switch 55/60" 55 5 100.0 1
check "90pct under 100 gate" 9 1 100.0 1
check "90pct over 80 gate" 9 1 80.0 0

# A missing or unparsable output.xml must fail, never silently pass.
rm -f "${tmp}/output.xml"
set +e
python3 "${gate}" "${tmp}/output.xml" 100.0 0.0 >/dev/null 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
    echo "ok: missing output.xml (exit ${rc})"
else
    echo "FAIL: missing output.xml should fail"
    fail=1
fi

if [ "${fail}" -eq 0 ]; then
    echo "PASS: robot gate behaves like the Jenkins publisher"
fi
exit "${fail}"
