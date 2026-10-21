#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check the robot result gate that run-test.sh applies.
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
check "empty run under 0 gate" 0 0 0.0 1

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
# A --splitlog run: log.html pulls its parts from log-*.js beside it.
printf '<html>green log</html>' >"${res}/job-green/log.html"
printf 'window.output = {};' >"${res}/job-green/log-1.js"
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
    GITHUB_REPOSITORY=example-org/example-repo \
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
    "https://github.com/example-org/example-repo/actions/runs/42"
check_site "lists a passing job" "job-green"
check_site "keeps the job with no results" '<tr class="missing"><td>job-gone</td>'
check_site "offers the markdown" 'href="csit-summary.md"'
check_site "links the job's own robot report" 'href="jobs/job-green/report.html"'

if [ -s "${tmp}/site/jobs/job-green/report.html" ]; then
    echo "ok: site carries a copy of the job's robot report"
else
    echo "FAIL: job report.html not copied into the site"
    fail=1
fi

if [ -s "${tmp}/site/jobs/job-green/log-1.js" ]; then
    echo "ok: site keeps the split log parts log.html loads"
else
    echo "FAIL: --splitlog part log-1.js not copied into the site"
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

# The fan-out table must agree with each job's own gate: a 9/10 job that
# passed its 80% robot-pass-threshold is green, not red at a fixed 100%.
lax="${tmp}/lax"
mkdir -p "${lax}/job-lax"
cat >"${lax}/job-lax/output.xml" <<'EOF'
<robot name="Lax"><statistics><total>
<stat pass="9" fail="1">All Tests</stat>
</total></statistics></robot>
EOF
python3 "${gate}" "${lax}/job-lax/output.xml" 80.0 0.0 >/dev/null
if grep -qF '"pass_threshold": 80.0' "${lax}/job-lax/robot-gate.json" 2>/dev/null; then
    echo "ok: gate records the threshold it applied"
else
    echo "FAIL: gate did not write robot-gate.json beside output.xml"
    fail=1
fi
printf '<html>lax report</html>' >"${lax}/job-lax/report.html"
# Publishing the site into the results directory itself must not crash on
# copying a report onto itself.
if (cd "${tmp}" && python3 "${gate}" --summary lax "" --html lax >/dev/null) &&
    grep -qF '"green": 1' "${lax}/report.json"; then
    echo "ok: summary honours the job's threshold, site builds in place"
else
    echo "FAIL: 9/10 under an 80% threshold not green, or in-place site failed"
    fail=1
fi
# A site published into a subdirectory of the results must not be mistaken
# for a job when the report is rendered again.
for _ in 1 2; do
    (cd "${tmp}" && python3 "${gate}" --summary lax "" --html lax/site >/dev/null)
done
if grep -qF '"green": 1' "${lax}/site/report.json" &&
    grep -qF '"jobs": 1' "${lax}/site/report.json"; then
    echo "ok: republishing into results/site keeps the job count"
else
    echo "FAIL: site directory under results counted as a job"
    fail=1
fi
# Rendering again without --html must still skip the site published earlier.
summary_only="$(cd "${tmp}" && python3 "${gate}" --summary lax "")"
if grep -qF "1/1 jobs green" <<<"${summary_only}"; then
    echo "ok: summary without --html skips an earlier published site"
else
    echo "FAIL: earlier published site counted as a job without --html"
    fail=1
fi

# A site published inside a job's directory must not hide that job: the
# output location cannot change the fan-out verdict.
nest="${tmp}/nest"
mkdir -p "${nest}/green" "${nest}/red"
printf '<robot><statistics><total><stat pass="%s" fail="%s">All Tests</stat></total></statistics></robot>\n' \
    3 0 >"${nest}/green/output.xml"
printf '<robot><statistics><total><stat pass="%s" fail="%s">All Tests</stat></total></statistics></robot>\n' \
    2 1 >"${nest}/red/output.xml"
(cd "${tmp}" && python3 "${gate}" --summary nest "" --html nest/red/site >/dev/null) || true
if grep -qF '"jobs": 2' "${nest}/red/site/report.json" &&
    grep -qF '"green": 1' "${nest}/red/site/report.json"; then
    echo "ok: a site inside a job directory keeps that job counted"
else
    echo "FAIL: publishing into a job directory dropped the job"
    fail=1
fi

# Publishing the site straight into a job's directory is refused, and a stale
# site marker left in a job's directory does not hide that job either.
if (cd "${tmp}" && python3 "${gate}" --summary nest "" --html nest/red \
    >/dev/null 2>&1); then
    echo "FAIL: --html into a job directory was accepted"
    fail=1
elif [ -e "${nest}/red/index.html" ]; then
    echo "FAIL: a refused --html still wrote into the job directory"
    fail=1
else
    echo "ok: --html into a job directory is refused"
fi
touch "${nest}/red/.csit-site"
(cd "${tmp}" && python3 "${gate}" --summary nest "" --html nest-site >/dev/null) || true
if grep -qF '"jobs": 2' "${tmp}/nest-site/report.json"; then
    echo "ok: a site marker does not hide a job with results"
else
    echo "FAIL: a site marker hid a job that has output.xml"
    fail=1
fi

# The verdict replaces a planted robot-gate.json symlink rather than writing
# through it to the link's target.
plant="${tmp}/plant"
mkdir -p "${plant}"
echo keep >"${tmp}/plant-target"
cp "${nest}/green/output.xml" "${plant}/output.xml"
ln -s "${tmp}/plant-target" "${plant}/robot-gate.json"
python3 "${gate}" "${plant}/output.xml" 100.0 0.0 >/dev/null || true
if [ "$(cat "${tmp}/plant-target")" = keep ] &&
    [ ! -L "${plant}/robot-gate.json" ] &&
    grep -qF '"ok": true' "${plant}/robot-gate.json"; then
    echo "ok: the verdict replaces a symlinked robot-gate.json"
else
    echo "FAIL: the verdict wrote through a symlinked robot-gate.json"
    fail=1
fi

# Robot Framework 3 lists Critical Tests before All Tests: 1/1 critical but
# 1/2 overall is a 50% run, not a 100% one.
rf3="${tmp}/rf3"
mkdir -p "${rf3}"
cat >"${rf3}/output.xml" <<'XML'
<robot><statistics><total>
<stat pass="1" fail="0">Critical Tests</stat>
<stat pass="1" fail="1">All Tests</stat>
</total></statistics></robot>
XML
if out="$(python3 "${gate}" "${rf3}/output.xml" 100.0 0.0 2>&1)"; then
    echo "FAIL: Critical Tests total passed a 50% run"
    fail=1
elif [[ "$out" == *"1/2 passed (50.00%)"* ]]; then
    echo "ok: the gate counts All Tests, not Critical Tests"
else
    echo "FAIL: unexpected gate output for RF3 statistics: ${out}"
    fail=1
fi

# A job that crashed before writing output.xml leaves an empty directory; a
# site published there would hide it, so --html refuses it.
crash="${tmp}/crash"
mkdir -p "${crash}/green" "${crash}/crashed"
cp "${nest}/green/output.xml" "${crash}/green/output.xml"
if (cd "${tmp}" && python3 "${gate}" --summary crash "" --html crash/crashed \
    >/dev/null 2>&1); then
    echo "FAIL: --html into a crashed job's directory was accepted"
    fail=1
elif [ -e "${crash}/crashed/.csit-site" ]; then
    echo "FAIL: a refused --html still marked the crashed job as a site"
    fail=1
else
    (cd "${tmp}" && python3 "${gate}" --summary crash "" --html crash-site \
        >/dev/null) || true
    if grep -qF '"jobs": 2' "${tmp}/crash-site/report.json"; then
        echo "ok: a crashed job's directory is refused and still counted"
    else
        echo "FAIL: the crashed job disappeared from the report"
        fail=1
    fi
fi

# A lone Critical Tests total is not the run's total: without All Tests the
# file is unusable, never a pass.
cat >"${rf3}/output.xml" <<'XML'
<robot><statistics><total>
<stat pass="1" fail="0">Critical Tests</stat>
</total></statistics></robot>
XML
if python3 "${gate}" "${rf3}/output.xml" 0.0 0.0 >/dev/null 2>&1; then
    echo "FAIL: a lone Critical Tests total passed the gate"
    fail=1
else
    echo "ok: the gate requires the All Tests total"
fi

# Job names cannot collide with the site's own files, and Robot resources
# in subdirectories travel with the job's log.
clash="${tmp}/clash"
mkdir -p "${clash}/index.html/screenshots" "${clash}/index.html/old/.git"
cp "${nest}/green/output.xml" "${clash}/index.html/output.xml"
printf '<html>log</html>' >"${clash}/index.html/log.html"
printf 'png' >"${clash}/index.html/screenshots/failure.png"
mkdir -p "${clash}/index.html/published"
touch "${clash}/index.html/published/.csit-site"
printf 'png' >"${clash}/index.html/published/stale.png"
if (cd "${tmp}" && python3 "${gate}" --summary clash "" --html clash-site \
    >/dev/null 2>&1) &&
    [ -f "${tmp}/clash-site/index.html" ] &&
    grep -qF 'href="jobs/index.html/log.html"' "${tmp}/clash-site/index.html"; then
    echo "ok: a job named index.html does not collide with the landing page"
else
    echo "FAIL: a job named like a site file broke the site"
    fail=1
fi
if [ -s "${tmp}/clash-site/jobs/index.html/screenshots/failure.png" ] &&
    [ ! -e "${tmp}/clash-site/jobs/index.html/published/stale.png" ]; then
    echo "ok: resource subdirectories are copied, published sites are not"
else
    echo "FAIL: drill-down resources missing or a published site copied"
    fail=1
fi

# A symlinked report, log or job directory may point at any runner file;
# none of it reaches the public site.
leak="${tmp}/leak"
mkdir -p "${leak}/linked-log" "${tmp}/elsewhere"
printf 'runner secret' >"${tmp}/secret.txt"
cp "${nest}/green/output.xml" "${leak}/linked-log/output.xml"
ln -s "${tmp}/secret.txt" "${leak}/linked-log/log.html"
ln -s "${tmp}/secret.txt" "${leak}/linked-log/report.html"
cp "${nest}/green/output.xml" "${tmp}/elsewhere/output.xml"
cp "${tmp}/secret.txt" "${tmp}/elsewhere/log.html"
ln -s "${tmp}/elsewhere" "${leak}/linked-dir"
(cd "${tmp}" && python3 "${gate}" --summary leak "" --html leak-site \
    >/dev/null 2>&1) || true
if [ -f "${tmp}/leak-site/index.html" ] &&
    ! grep -rqF 'runner secret' "${tmp}/leak-site"; then
    echo "ok: symlinked reports and job directories are not published"
else
    echo "FAIL: a symlink leaked a runner file into the site"
    fail=1
fi

# A results root reached through a symlink is no safer than a linked job.
mkdir -p "${tmp}/outside/job"
cp "${tmp}/elsewhere/output.xml" "${tmp}/elsewhere/log.html" "${tmp}/outside/job/"
ln -s "${tmp}/outside" "${tmp}/via"
(cd "${tmp}" && python3 "${gate}" --summary via "" --html via-site \
    >/dev/null 2>&1) || true
if [ -f "${tmp}/via-site/index.html" ] &&
    ! grep -rqF 'runner secret' "${tmp}/via-site"; then
    echo "ok: a symlinked ancestor of the results is not published"
else
    echo "FAIL: a symlinked results ancestor leaked a runner file"
    fail=1
fi

# A listed job name is a single directory name, never a path.
printf '../elsewhere\n' >"${tmp}/escape.txt"
if (cd "${tmp}" && python3 "${gate}" --summary leak "${tmp}/escape.txt" \
    --html escape-site >/dev/null 2>&1); then
    echo "FAIL: a job name with a path escaped the results root"
    fail=1
elif [ -e "${tmp}/escape-site" ]; then
    echo "FAIL: a rejected job list still published a site"
    fail=1
else
    echo "ok: job names that are paths are refused"
fi

# Republishing rebuilds the drill-down tree: nothing stale survives.
stale="${tmp}/stale"
mkdir -p "${stale}/green/shots"
cp "${nest}/green/output.xml" "${stale}/green/output.xml"
printf '<html>log</html>' >"${stale}/green/log.html"
printf 'png' >"${stale}/green/shots/old.png"
(cd "${tmp}" && python3 "${gate}" --summary stale "" --html stale-site \
    >/dev/null 2>&1) || true
rm -f "${stale}/green/shots/old.png"
mv "${stale}/green" "${stale}/blue"
(cd "${tmp}" && python3 "${gate}" --summary stale "" --html stale-site \
    >/dev/null 2>&1) || true
if [ -s "${tmp}/stale-site/jobs/blue/log.html" ] &&
    [ ! -e "${tmp}/stale-site/jobs/green" ]; then
    echo "ok: a republished site drops vanished drill-downs"
else
    echo "FAIL: stale drill-downs survived a republish"
    fail=1
fi

# A jobs directory holding results is a job, never a tree to rebuild.
mkdir -p "${tmp}/held/jobs"
touch "${tmp}/held/jobs/.csit-site"
cp "${nest}/green/output.xml" "${tmp}/held/jobs/output.xml"
if (cd "${tmp}" && python3 "${gate}" --summary stale "" --html held \
    >/dev/null 2>&1) || [ ! -s "${tmp}/held/jobs/output.xml" ]; then
    echo "FAIL: a jobs directory holding output.xml was overwritten"
    fail=1
else
    echo "ok: a jobs directory holding results is refused"
fi

# A stale site may hold links; republishing replaces them, never writing
# through to the runner file they point at.
mkdir -p "${tmp}/linked-site"
printf 'keep me' >"${tmp}/victim.txt"
for f in index.html report.json csit-summary.md .csit-site; do
    ln -sf "${tmp}/victim.txt" "${tmp}/linked-site/${f}"
done
ln -sf "${tmp}/victim.txt" "${tmp}/csit-summary.md"
(cd "${tmp}" && python3 "${gate}" --summary stale "" --html linked-site \
    >/dev/null 2>&1) || true
if [ "$(cat "${tmp}/victim.txt")" = "keep me" ] &&
    [ ! -L "${tmp}/linked-site/index.html" ] &&
    [ ! -L "${tmp}/csit-summary.md" ]; then
    echo "ok: generated files replace symlinks instead of writing through"
else
    echo "FAIL: a generated file wrote through a symlink"
    fail=1
fi
rm -f "${tmp}/csit-summary.md"

# A job named like the marker still gets its drill-down.
odd="${tmp}/odd"
mkdir -p "${odd}/.csit-site"
cp "${nest}/green/output.xml" "${odd}/.csit-site/output.xml"
printf '<html>log</html>' >"${odd}/.csit-site/log.html"
if (cd "${tmp}" && python3 "${gate}" --summary odd "" --html odd-site \
    >/dev/null 2>&1) && [ -s "${tmp}/odd-site/jobs/.csit-site/log.html" ]; then
    echo "ok: a job named like the site marker is published"
else
    echo "FAIL: a job named like the site marker broke the site"
    fail=1
fi

# In place, a job directory where a site file goes is refused up front.
inner="${tmp}/inner"
mkdir -p "${inner}/report.json"
cp "${nest}/green/output.xml" "${inner}/report.json/output.xml"
if (cd "${tmp}" && python3 "${gate}" --summary inner "" --html inner \
    >/dev/null 2>&1); then
    echo "FAIL: publishing in place over a job named report.json succeeded"
    fail=1
elif [ -e "${inner}/index.html" ]; then
    echo "FAIL: a refused in-place site was partly written"
    fail=1
else
    echo "ok: in-place collisions with site files are refused"
fi

# Linked results or threshold files cannot decide the public verdict.
verd="${tmp}/verd"
mkdir -p "${verd}/half" "${verd}/borrowed" "${tmp}/ext"
cat >"${verd}/half/output.xml" <<'XML'
<robot><statistics><total>
<stat pass="1" fail="1">All Tests</stat>
</total></statistics></robot>
XML
printf '{"pass_threshold": 0}' >"${tmp}/ext/gate.json"
ln -s "${tmp}/ext/gate.json" "${verd}/half/robot-gate.json"
cp "${nest}/green/output.xml" "${tmp}/ext/output.xml"
ln -s "${tmp}/ext/output.xml" "${verd}/borrowed/output.xml"
(cd "${tmp}" && python3 "${gate}" --summary verd "" --html verd-site \
    >/dev/null 2>&1) || true
if grep -qF '"green": 0' "${tmp}/verd-site/report.json" &&
    grep -qF '"missing"' "${tmp}/verd-site/report.json"; then
    echo "ok: linked results and thresholds do not turn jobs green"
else
    echo "FAIL: a linked output.xml or robot-gate.json changed the verdict"
    fail=1
fi

# Publishing under a results root that does not exist yet still marks the
# parent it creates.
for _ in 1 2; do
    (cd "${tmp}" && python3 "${gate}" --summary fresh "" \
        --html fresh/published/site >/dev/null 2>&1) || true
done
mkdir -p "${tmp}/fresh/green"
cp "${nest}/green/output.xml" "${tmp}/fresh/green/output.xml"
(cd "${tmp}" && python3 "${gate}" --summary fresh "" \
    --html fresh/published/site >/dev/null 2>&1) || true
if grep -qF '"jobs": 1' "${tmp}/fresh/published/site/report.json"; then
    echo "ok: a parent created with an absent results root is not a job"
else
    echo "FAIL: publishing before any results added a phantom job"
    fail=1
fi

# A linked marker does not make a directory publisher-owned: a crashed job
# keeps its row, cannot be published into, and an html/jobs tree with one
# is not deleted.
fake="${tmp}/fake"
mkdir -p "${fake}/green" "${fake}/crashed"
cp "${nest}/green/output.xml" "${fake}/green/output.xml"
echo keep >"${tmp}/ext/marker"
ln -s "${tmp}/ext/marker" "${fake}/crashed/.csit-site"
(cd "${tmp}" && python3 "${gate}" --summary fake "" --html fake-site \
    >/dev/null 2>&1) || true
rc=0
(cd "${tmp}" && python3 "${gate}" --summary fake "" --html fake/crashed \
    >/dev/null 2>&1) || rc=$?
mkdir -p "${tmp}/fake2/green" "${tmp}/fake2/site/jobs"
cp "${nest}/green/output.xml" "${tmp}/fake2/green/output.xml"
echo keep >"${tmp}/fake2/site/jobs/keep.txt"
ln -s "${tmp}/ext/marker" "${tmp}/fake2/site/jobs/.csit-site"
(cd "${tmp}" && python3 "${gate}" --summary fake2 "" --html fake2/site \
    >/dev/null 2>&1) || true
if grep -qF '"jobs": 2' "${tmp}/fake-site/report.json" && [ "$rc" -ne 0 ] &&
    [ ! -e "${fake}/crashed/index.html" ] &&
    [ -f "${tmp}/fake2/site/jobs/keep.txt" ]; then
    echo "ok: a linked marker does not claim a directory for the site"
else
    echo "FAIL: a linked .csit-site marker was trusted"
    fail=1
fi

# A real marker in a linked job's target does not hide the missing row, and
# a piped job name stays in its own table cell.
pipe="${tmp}/pipe"
mkdir -p "${pipe}/smoke | IPv6" "${tmp}/ext/owned"
cp "${nest}/green/output.xml" "${pipe}/smoke | IPv6/output.xml"
: >"${tmp}/ext/owned/.csit-site"
ln -s "${tmp}/ext/owned" "${pipe}/crashed"
(cd "${tmp}" && python3 "${gate}" --summary pipe "" --html pipe-site \
    >/dev/null 2>&1) || true
if grep -qF '"jobs": 2' "${tmp}/pipe-site/report.json" &&
    grep -qF '| smoke \| IPv6 | 3/3 | 100.00% |' "${tmp}/pipe-site/csit-summary.md"; then
    echo "ok: a linked job and a piped job name keep their rows"
else
    echo "FAIL: a linked job hid its row or a piped name split the table"
    fail=1
fi

# A marker beside a dangling output.xml link does not hide a crashed job,
# nor let a site be published into it.
dang="${tmp}/dang"
mkdir -p "${dang}/green" "${dang}/crashed"
cp "${nest}/green/output.xml" "${dang}/green/output.xml"
: >"${dang}/crashed/.csit-site"
ln -s "${tmp}/ext/no-such.xml" "${dang}/crashed/output.xml"
(cd "${tmp}" && python3 "${gate}" --summary dang "" --html dang-site \
    >/dev/null 2>&1) || true
rc=0
(cd "${tmp}" && python3 "${gate}" --summary dang "" --html dang/crashed \
    >/dev/null 2>&1) || rc=$?
if grep -qF '"jobs": 2' "${tmp}/dang-site/report.json" && [ "$rc" -ne 0 ] &&
    [ ! -e "${dang}/crashed/index.html" ]; then
    echo "ok: a dangling output.xml link keeps a marked job counted"
else
    echo "FAIL: a marker beside a dangling output.xml link hid the job"
    fail=1
fi

# Results downloaded into a site's own jobs tree are refused, not deleted
# by the rebuild.
mkdir -p "${tmp}/inside-src/green"
cp "${nest}/green/output.xml" "${tmp}/inside-src/green/output.xml"
(cd "${tmp}" && python3 "${gate}" --summary inside-src "" --html inside \
    >/dev/null 2>&1) || true
mkdir -p "${tmp}/inside/jobs/green"
cp "${nest}/green/output.xml" "${tmp}/inside/jobs/green/output.xml"
rc=0
(cd "${tmp}" && python3 "${gate}" --summary inside/jobs "" --html inside \
    >/dev/null 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && [ -f "${tmp}/inside/jobs/green/output.xml" ]; then
    echo "ok: results inside the site's jobs tree are refused and kept"
else
    echo "FAIL: publishing over the results root's jobs tree (rc ${rc})"
    fail=1
fi

# A linked results root is absent: auto-discovery does not publish the
# names under its target, but listed jobs still get their missing rows.
mkdir -p "${tmp}/lroot-target/confidential-directory-name"
ln -s "${tmp}/lroot-target" "${tmp}/lroot"
printf 'listed-job\n' >"${tmp}/lroot-list.txt"
(cd "${tmp}" && python3 "${gate}" --summary lroot "" --html lroot-site \
    >/dev/null 2>&1) || true
(cd "${tmp}" && python3 "${gate}" --summary lroot lroot-list.txt \
    --html lroot-listed >/dev/null 2>&1) || true
if ! grep -rqF confidential-directory-name "${tmp}/lroot-site" &&
    grep -qF '"jobs": 0' "${tmp}/lroot-site/report.json" &&
    grep -qF listed-job "${tmp}/lroot-listed/report.json"; then
    echo "ok: a linked results root is not auto-discovered"
else
    echo "FAIL: auto-discovery followed a linked results root"
    fail=1
fi

# A job named csit-summary.md under results-dir . is kept: the working
# copy is skipped, and the site still gets its summary.
mkdir -p "${tmp}/sumdir/csit-summary.md"
cp "${nest}/green/output.xml" "${tmp}/sumdir/csit-summary.md/output.xml"
rc=0
(cd "${tmp}/sumdir" && python3 "${gate}" --summary . "" --html ../sumdir-site \
    >/dev/null 2>&1) || rc=$?
rc2=0
(cd "${tmp}/sumdir" && python3 "${gate}" --summary . >/dev/null 2>&1) || rc2=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] &&
    [ -f "${tmp}/sumdir/csit-summary.md/output.xml" ] &&
    [ -f "${tmp}/sumdir-site/csit-summary.md" ]; then
    echo "ok: a csit-summary.md job directory is kept"
else
    echo "FAIL: a csit-summary.md job directory broke the summary (${rc}/${rc2})"
    fail=1
fi

# An html-dir named csit-summary.md, or under it, is created before the
# working copy would claim that name as a file.
for dest in csit-summary.md csit-summary.md/site; do
    mkdir -p "${tmp}/sumsite"
    cp -r "${nest}/green" "${tmp}/sumsite/green"
    rc=0
    (cd "${tmp}/sumsite" && python3 "${gate}" --summary . "" --html "$dest" \
        >/dev/null 2>&1) || rc=$?
    if [ "$rc" -eq 0 ] && [ -f "${tmp}/sumsite/${dest}/index.html" ]; then
        echo "ok: html-dir ${dest} is published"
    else
        echo "FAIL: html-dir ${dest} was not published (${rc})"
        fail=1
    fi
    rm -rf "${tmp}/sumsite"
done

# A symlink left in the published tree would be followed by the Pages
# upload, so publishing is refused and the source results are kept.
mkdir -p "${tmp}/inlink/green" "${tmp}/outlink/extra"
cp "${nest}/green/output.xml" "${tmp}/inlink/green/output.xml"
printf 'secret\n' >"${tmp}/runner-secret"
ln -s "${tmp}/runner-secret" "${tmp}/inlink/green/log.html"
ln -s "${tmp}/runner-secret" "${tmp}/outlink/extra/leak"
rc=0
(cd "${tmp}" && python3 "${gate}" --summary inlink "" --html inlink \
    >/dev/null 2>&1) || rc=$?
rc2=0
(cd "${tmp}" && python3 "${gate}" --summary inlink-none "" --html outlink \
    >/dev/null 2>&1) || rc2=$?
if [ "$rc" -eq 2 ] && [ "$rc2" -eq 2 ] && [ ! -e "${tmp}/inlink/index.html" ] &&
    [ ! -e "${tmp}/outlink/index.html" ] && [ -L "${tmp}/inlink/green/log.html" ]; then
    echo "ok: a site tree holding a symlink is refused"
else
    echo "FAIL: published a site tree holding a symlink (${rc}/${rc2})"
    fail=1
fi

# A linked destination, or one under a linked ancestor, is refused before
# anything is written through it, even when it is also the results root.
mkdir -p "${tmp}/ltarget/sub" "${tmp}/lsrc/green"
cp "${nest}/green/output.xml" "${tmp}/lsrc/green/output.xml"
ln -s "${tmp}/ltarget" "${tmp}/lsite"
rcs=""
for dest in lsite lsite/sub; do
    for src in lsrc "$dest"; do
        rc=0
        (cd "${tmp}" && python3 "${gate}" --summary "$src" "" --html "$dest" \
            >/dev/null 2>&1) || rc=$?
        rcs="${rcs}${rc}"
    done
done
if [ "$rcs" = "2222" ] && [ -z "$(find "${tmp}/ltarget" -type f)" ]; then
    echo "ok: a linked destination or ancestor is refused"
else
    echo "FAIL: published through a linked destination (${rcs})"
    fail=1
fi

# A job named output.xml can be republished to the same site: its drill-down
# directory is not a result.
mkdir -p "${tmp}/oxsrc/output.xml"
cp "${nest}/green/output.xml" "${tmp}/oxsrc/output.xml/output.xml"
printf '<html></html>\n' >"${tmp}/oxsrc/output.xml/report.html"
rcs=""
for _ in 1 2; do
    rc=0
    (cd "${tmp}" && python3 "${gate}" --summary oxsrc "" --html oxsite \
        >/dev/null 2>&1) || rc=$?
    rcs="${rcs}${rc}"
done
if [ "$rcs" = "00" ] && [ -f "${tmp}/oxsite/jobs/output.xml/report.html" ]; then
    echo "ok: a job named output.xml republishes"
else
    echo "FAIL: a job named output.xml blocked republication (${rcs})"
    fail=1
fi

# In place, a dangling job link named like a site file or jobs/ is refused
# rather than overwritten, which would turn a missing job green next time.
for name in index.html report.json csit-summary.md .csit-site jobs; do
    ip="${tmp}/iplink-${name}"
    mkdir -p "${ip}/green"
    cp "${nest}/green/output.xml" "${ip}/green/output.xml"
    ln -s "${tmp}/no-such-job" "${ip}/${name}"
    if (cd "${ip}" && python3 "${gate}" --summary . "" --html . \
        >/dev/null 2>&1) || [ ! -L "${ip}/${name}" ]; then
        echo "FAIL: in place, a dangling job link ${name} was overwritten"
        fail=1
    else
        echo "ok: in place, a dangling job link ${name} is refused"
    fi
done

# A dangling job link alongside a passing job still reports missing when no
# job list is given, rather than vanishing and turning the run green.
mkdir -p "${tmp}/dsrc/green"
cp "${nest}/green/output.xml" "${tmp}/dsrc/green/output.xml"
ln -s "${tmp}/no-such-job" "${tmp}/dsrc/gone"
(cd "${tmp}" && python3 "${gate}" --summary dsrc "" --html dsite \
    >/dev/null 2>&1) || true
if grep -qF '"jobs": 2' "${tmp}/dsite/report.json" &&
    grep -qF '| gone | – | – | ⚠️ no results |' "${tmp}/dsite/csit-summary.md"; then
    echo "ok: a dangling job link reports missing"
else
    echo "FAIL: a dangling job link vanished from the report"
    fail=1
fi

# A `..` after a name in the destination is refused before anything is
# created, so a missing component cannot hide a linked destination and its
# retained links. A leading `..` is the cwd's real parent and still works.
mkdir -p "${tmp}/dotsrc/green" "${tmp}/dottarget"
cp "${nest}/green/output.xml" "${tmp}/dotsrc/green/output.xml"
ln -s "${tmp}/secret.txt" "${tmp}/dottarget/leak.txt"
ln -s "${tmp}/dottarget" "${tmp}/dotsite"
rc=0
(cd "${tmp}" && python3 "${gate}" --summary dotsrc "" \
    --html not-created/../dotsite >/dev/null 2>&1) || rc=$?
rc2=0
(cd "${tmp}/dotsrc" && python3 "${gate}" --summary . "" \
    --html ../dotup >/dev/null 2>&1) || rc2=$?
if [ "$rc" -eq 2 ] && [ ! -e "${tmp}/not-created" ] &&
    [ ! -e "${tmp}/dottarget/index.html" ] &&
    [ "$rc2" -eq 0 ] && [ -f "${tmp}/dotup/index.html" ]; then
    echo "ok: a destination with .. after a name is refused, a leading .. is not"
else
    echo "FAIL: .. in the destination mishandled (${rc}/${rc2})"
    fail=1
fi

# A missing job linked as csit-summary.md under results-dir . is kept, so
# a second render still reports it rather than turning green.
mkdir -p "${tmp}/sumlink/green"
cp "${nest}/green/output.xml" "${tmp}/sumlink/green/output.xml"
ln -s "${tmp}/no-such-job" "${tmp}/sumlink/csit-summary.md"
for _ in 1 2; do
    (cd "${tmp}/sumlink" && python3 "${gate}" --summary . "" \
        --html ../sumlink-site >/dev/null 2>&1) || true
done
# The same root spelled another way, here ../sumlink2, is still the cwd.
mkdir -p "${tmp}/sumlink2/green"
cp "${nest}/green/output.xml" "${tmp}/sumlink2/green/output.xml"
ln -s "${tmp}/no-such-job" "${tmp}/sumlink2/csit-summary.md"
for _ in 1 2; do
    (cd "${tmp}/sumlink2" && python3 "${gate}" --summary ../sumlink2 "" \
        --html ../sumlink2-site >/dev/null 2>&1) || true
done
if [ -L "${tmp}/sumlink/csit-summary.md" ] &&
    grep -qF '"jobs": 2' "${tmp}/sumlink-site/report.json" &&
    [ -L "${tmp}/sumlink2/csit-summary.md" ] &&
    grep -qF '"jobs": 2' "${tmp}/sumlink2-site/report.json"; then
    echo "ok: a csit-summary.md job link survives a second render"
else
    echo "FAIL: a csit-summary.md job link was replaced"
    fail=1
fi

# Publishing in place keeps the drill-down tree out of the job list.
inplace="${tmp}/inplace"
mkdir -p "${inplace}/green"
cp "${nest}/green/output.xml" "${inplace}/green/output.xml"
for _ in 1 2; do
    (cd "${tmp}" && python3 "${gate}" --summary inplace "" --html inplace \
        >/dev/null) || true
done
if grep -qF '"jobs": 1' "${inplace}/report.json"; then
    echo "ok: an in-place site's jobs directory is not a job"
else
    echo "FAIL: an in-place site's drill-down tree was counted as a job"
    fail=1
fi

# A nested destination creates its parent under the results; that parent is
# not a job on the next render.
pub="${tmp}/pub"
mkdir -p "${pub}/green"
cp "${nest}/green/output.xml" "${pub}/green/output.xml"
for _ in 1 2; do
    (cd "${tmp}" && python3 "${gate}" --summary pub "" --html pub/published/site \
        >/dev/null) || true
done
if grep -qF '"jobs": 1' "${pub}/published/site/report.json"; then
    echo "ok: a parent created for a nested site is not a job"
else
    echo "FAIL: publishing into a nested site added a phantom job"
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
  <suite id="s1-s3" name="HTTP | HTTPS">
    <test id="s1-s3-t1" name="Get"><status status="PASS"/></test>
  </suite>
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
check_job "keeps a piped suite name in its own cell" \
    "| Ovsdb.HTTP \\| HTTPS | 1 | 1 | 0 | 0 | 100.00% |"
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
