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

# The gate writes its markdown to $GITHUB_STEP_SUMMARY when set and to stdout
# otherwise. Pin it to a temp file so this suite exercises the path that
# actually runs in CI, keeps its assertions off stdout, and does not append
# fixture results to a real run summary. Without this the summary assertions
# below pass locally and go vacuous on a runner, where the variable is always
# set.
export GITHUB_STEP_SUMMARY="${tmp}/step-summary.md"

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

# --- summary mode ----------------------------------------------------------
# The go/no-go table decides whether a release ships, so a job that produced
# no output.xml must appear as an error row, not vanish from the table.
res="${tmp}/results"
mkdir -p "${res}/job-green" "${res}/job-red" "${res}/job-empty"
cat >"${res}/job-green/output.xml" <<'EOF'
<robot name="Daexim"><statistics><total>
<stat pass="9" fail="0">All Tests</stat>
</total></statistics></robot>
EOF
cat >"${res}/job-red/output.xml" <<'EOF'
<robot name="L2Switch"><statistics><total>
<stat pass="55" fail="5">All Tests</stat>
</total></statistics></robot>
EOF
printf '<html>green report</html>' >"${res}/job-green/report.html"
# job-empty has a directory but no output.xml (crashed before robot).
# job-gone has no directory at all (artifact upload found nothing).
printf 'job-green\njob-red\njob-empty\njob-gone\n' >"${tmp}/expected.txt"

: >"${GITHUB_STEP_SUMMARY}"
(cd "${tmp}" && python3 "${gate}" --summary results expected.txt >/dev/null)
sum_out="$(cat "${GITHUB_STEP_SUMMARY}")"

check_has() {
    if grep -qF -- "$2" <<<"${sum_out}"; then
        echo "ok: summary $1"
    else
        echo "FAIL: summary $1: missing '$2'"
        echo "${sum_out}"
        fail=1
    fi
}

# --- published site --------------------------------------------------------
# A release page that quietly omitted a job that never ran would be worse than
# no page at all, so assert the missing job survives into HTML and JSON too.
(cd "${tmp}" && GITHUB_SERVER_URL=https://github.com \
    GITHUB_REPOSITORY=opendaylight/integration-distribution \
    GITHUB_RUN_ID=42 \
    python3 "${gate}" --summary results expected.txt \
    --html site --title "distribution / vanadium" >/dev/null)
site_out="$(cat "${tmp}/site/index.html")"

check_site() {
    if grep -qF -- "$2" <<<"${site_out}"; then
        echo "ok: site $1"
    else
        echo "FAIL: site $1: missing '$2'"
        fail=1
    fi
}

check_site "carries the pipeline title" "distribution / vanadium"
check_site "shows the verdict" "1/4 jobs green"
check_site "links back to the run" \
    "https://github.com/opendaylight/integration-distribution/actions/runs/42"
check_site "lists a passing job" "job-green"
check_site "keeps the job with no results" '<tr class="missing"><td>job-gone</td>'
check_site "offers the markdown" 'href="csit-summary.md"'
check_site "links the job's own robot report" 'href="job-green/report.html"'

if [ -s "${tmp}/site/job-green/report.html" ]; then
    echo "ok: site carries a copy of the job's robot report"
else
    echo "FAIL: job report.html not copied into the site"
    fail=1
fi

if grep -qF 'href="job-gone/' <<<"${site_out}"; then
    echo "FAIL: site links a robot report for a job that produced none"
    fail=1
else
    echo "ok: site links no robot report for a job that produced none"
fi

if python3 - "${tmp}/site/report.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["green"] == 1 and d["jobs"] == 4, d
assert [r["job"] for r in d["results"]] == [
    "job-green", "job-red", "job-empty", "job-gone"], d
assert d["results"][3]["state"] == "missing", d
PYEOF
then
    echo "ok: report.json keeps every dispatched job"
else
    echo "FAIL: report.json does not match the dispatched job list"
    fail=1
fi

# --- per-job report ------------------------------------------------------
#
# Every job carries its own verdict on its own run page, and that page has to
# account for every test: a suite that ran and a suite that vanished look the
# same if only totals are printed.
cat >"${tmp}/detail.xml" <<'EOF'
<robot>
<suite id="s1" name="Ovsdb">
  <suite id="s1-s1" name="Southbound">
    <test id="s1-s1-t1" name="Connect"><status status="PASS"/></test>
    <test id="s1-s1-t2" name="Disconnect"><status status="FAIL"/></test>
    <test id="s1-s1-t3" name="Skipped One"><status status="SKIP"/></test>
  </suite>
  <suite id="s1-s2" name="Empty Suite"/>
</suite>
<statistics><total><stat pass="1" fail="1" skip="1">All Tests</stat></total></statistics>
</robot>
EOF
: >"${GITHUB_STEP_SUMMARY}"
CSIT_JOB=ovsdb-csit-1node-southbound-only-vanadium \
    python3 "${gate}" "${tmp}/detail.xml" 100.0 0.0 >/dev/null 2>&1 || true
job_out="$(cat "${GITHUB_STEP_SUMMARY}")"

check_job() {
    if grep -qF -- "$2" <<<"${job_out}"; then
        echo "ok: per-job report $1"
    else
        echo "FAIL: per-job report $1: missing '$2'"
        echo "${job_out}"
        fail=1
    fi
}

check_job "is headed by the JJB job name" \
    "ovsdb-csit-1node-southbound-only-vanadium"
check_job "counts skips without letting them change the verdict" \
    "1/2 passed (50.00%), 1 skipped"
check_job "breaks results down per suite" \
    "| Ovsdb.Southbound | 3 | 1 | 1 | 1 | 50.00% |"
check_job "shows a suite that produced no tests at all" \
    "| Ovsdb.Empty Suite | 0 |"
check_job "names the failing test" "- Disconnect"
check_job "lists every test, not just the failures" $'- \u2705 Connect'
check_job "marks a skipped test as skipped" "Skipped One"

check_has "counts only green jobs" "1/4 jobs green"
check_has "lists a passing job" "| job-green | 9/9 | 100.00% |"
check_has "lists a failing job" "| job-red | 55/60 | 91.67% |"
check_has "keeps a job with no output.xml" "| job-empty |"
check_has "keeps a job with no artifact" "| job-gone |"

if [ -s "${tmp}/csit-summary.md" ]; then
    echo "ok: summary written to csit-summary.md"
else
    echo "FAIL: csit-summary.md not written"
    fail=1
fi

# Zero of zero is not success: an empty run must never render green.
: >"${GITHUB_STEP_SUMMARY}"
(cd "${tmp}" && python3 "${gate}" --summary no-such-dir "" >/dev/null)
sum_out="$(cat "${GITHUB_STEP_SUMMARY}")"
check_has "empty run is not green" "no jobs to report"
if grep -qF -- "all green" <<<"${sum_out}"; then
    echo "FAIL: empty run rendered as green"
    fail=1
else
    echo "ok: empty run avoids a green verdict"
fi

if [ "${fail}" -eq 0 ]; then
    echo "PASS: robot gate behaves like the Jenkins publisher"
fi
exit "${fail}"
