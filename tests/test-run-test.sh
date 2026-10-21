#!/usr/bin/env bash
# Test commands are single-quoted on purpose: run-test.sh expands them.
# shellcheck disable=SC2016
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check scripts/run-test.sh without a lab: a fake lab.env, extra-env parsing
# and refusal, and which of the command's exit status and the robot gate
# decides the verdict.
#
# Usage: tests/test-run-test.sh
##############################################################################

set -euo pipefail

# Relative on purpose: run-test.sh must find its helpers however it is called.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
run="scripts/run-test.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ws="${tmp}/ws"
mkdir -p "$ws"
cat >"${tmp}/lab.env" <<'ENV'
NUM_PROJECT_SYSTEM=1
PROJECT_SYSTEM_IP=10.0.0.2
PROJECT_SYSTEM_1_IP=10.0.0.2
NUM_ODL_SYSTEM=1
ODL_SYSTEM_1_IP=10.0.0.2
NUM_TOOLS_SYSTEM=0
ENV

robot() {
    printf '<robot><statistics><total><stat pass="%s" fail="%s">All Tests</stat></total></statistics></robot>\n' "$1" "$2"
}

fail=0
# $1 name, $2 expected exit (0 or 1), $3 expected output substring,
# $4 test command, $5 extra-env, then extra env assignments
check() {
    local name="$1" want_rc="$2" want="$3" cmd="$4" extra="$5" out rc=0
    shift 5
    out="$(env -i PATH="$PATH" HOME="$HOME" GITHUB_WORKSPACE="$ws" \
        GITHUB_STEP_SUMMARY="${tmp}/summary.md" CSIT_LAB_ENV="${tmp}/lab.env" \
        CSIT_TEST_COMMAND="$cmd" CSIT_EXTRA_ENV="$extra" "$@" \
        bash "$run" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then rc=1; fi
    if [ "$rc" -ne "$want_rc" ] || [[ "$out" != *"$want"* ]]; then
        echo "FAIL: ${name} (exit ${rc}, want ${want_rc} with '${want}')" >&2
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        fail=1
    else
        echo "ok: ${name}"
    fi
}
pass_xml="$(robot 3 0)"
fail_xml="$(robot 2 1)"

check "lab and extra env reach the command" 0 "ip=10.0.0.2 odl=10.0.0.2 a=x=y b=two words" \
    'echo "ip=$PROJECT_SYSTEM_IP odl=$ODL_SYSTEM_1_IP a=$A b=$B" >&2; echo "$X" > output.xml' \
    $'# comment\n\nA=x=y\r\nB=two words' X="$pass_xml"
check "runs in the workspace with CSIT_ACTION_PATH" 0 "here=${ws} action=ok" \
    'echo "here=$PWD action=$(test -x "$CSIT_ACTION_PATH/scripts/run-test.sh" && echo ok)" >&2; echo "$X" > output.xml' \
    "" X="$pass_xml"
check "gate passes despite non-zero robot exit" 0 "robot results decide" \
    'echo "$X" > output.xml; exit 3' "" X="$pass_xml"
check "gate fails below threshold" 1 "FAILED" \
    'echo "$X" > output.xml' "" X="$fail_xml"
check "threshold tolerates failures" 0 "2/3 passed" \
    'echo "$X" > output.xml' "" X="$fail_xml" ROBOT_PASS_THRESHOLD=50
check "custom robot-output path" 0 "3/3 passed" \
    'mkdir -p r; echo "$X" > r/out.xml' "" X="$pass_xml" CSIT_ROBOT_OUTPUT=r/out.xml
echo "$pass_xml" >"${ws}/output.xml"
check "stale output is removed first" 1 "cannot read output.xml" 'true' ""
check "no robot-output: exit 0 passes" 0 "" 'true' "" CSIT_ROBOT_OUTPUT=
check "no robot-output: exit status fails" 1 "exited 4" 'exit 4' "" CSIT_ROBOT_OUTPUT=

check "extra-env cannot replace runner internals" 0 "3/3 passed" \
    'echo "gate=$gate out=$CSIT_ROBOT_OUTPUT" >&2; echo "$X" > output.xml' \
    $'gate=/nonexistent\nscript_dir=/nonexistent\nCSIT_ROBOT_OUTPUT=none.xml\nROBOT_PASS_THRESHOLD_X=1' \
    X="$pass_xml"
check "extra-env reaches the command, not the runner" 0 "gate=/nonexistent out=none.xml" \
    'echo "gate=$gate out=$CSIT_ROBOT_OUTPUT" >&2; echo "$X" > output.xml' \
    $'gate=/nonexistent\nCSIT_ROBOT_OUTPUT=none.xml' X="$pass_xml"

for bad in PATH LD_PRELOAD BASH_ENV GITHUB_TOKEN RUNNER_TEMP HOME IFS WORKSPACE CSIT_ACTION_PATH; do
    check "refuses ${bad}" 1 "may not set ${bad}" 'true' "${bad}=x" CSIT_ROBOT_OUTPUT=
done
check "rejects a line without =" 1 "line 2 is not NAME=VALUE" 'true' $'A=1\nB' CSIT_ROBOT_OUTPUT=
check "rejects a bad name" 1 "not NAME=VALUE" 'true' '1A=1' CSIT_ROBOT_OUTPUT=
check "rejects an absolute robot-output" 1 "inside the workspace" 'true' '' CSIT_ROBOT_OUTPUT=/etc/x.xml
check "rejects .. in robot-output" 1 "inside the workspace" 'true' '' CSIT_ROBOT_OUTPUT=a/../../x.xml
check "needs a lab" 1 "run lab-up first" 'true' '' CSIT_LAB_ENV=

# robot-output must stay in the workspace through symlinks too: nothing
# outside is deleted or written, and a symlinked output.xml itself goes.
outside="${tmp}/outside"
mkdir -p "$outside"
for f in log.html report.html robot-gate.json target.xml; do
    echo keep >"${outside}/${f}"
done
ln -s "$outside" "${ws}/linked"
check "rejects a symlinked robot-output directory" 1 "outside the workspace" \
    'touch ran' '' CSIT_ROBOT_OUTPUT=linked/output.xml
check "rejects missing directories under an external link" 1 "outside the workspace" \
    'touch ran' '' CSIT_ROBOT_OUTPUT=linked/new/deeper/output.xml
ln -s "${tmp}/nowhere" "${ws}/dangling"
check "rejects a dangling symlinked directory" 1 "dangling symlink dangling" \
    'touch ran' '' CSIT_ROBOT_OUTPUT=dangling/new/output.xml
ln -s "$outside" "${ws}/nl"$'\n'
check "rejects a line break in robot-output" 1 "must not contain a line break" \
    'touch ran' '' CSIT_ROBOT_OUTPUT=nl$'\n'/target.xml
# Command substitution strips a trailing newline, so a link to the sibling
# "${ws}<newline>" must not pass as the workspace itself.
mkdir "${ws}"$'\n'
echo keep >"${ws}"$'\n'/output.xml
ln -s "${ws}"$'\n' "${ws}/nlws"
check "rejects a link to a newline-suffixed sibling" 1 "outside the workspace" \
    'touch ran' '' CSIT_ROBOT_OUTPUT=nlws/output.xml
check "leaves the newline-suffixed sibling's results" 0 "" \
    'test "$(cat "$D/output.xml")" = keep' '' D="${ws}"$'\n' CSIT_ROBOT_OUTPUT=
ln -s "${outside}/target.xml" "${ws}/leaf.xml"
check "removes a symlinked output.xml, not its target" 1 "cannot read leaf.xml" \
    'true' '' CSIT_ROBOT_OUTPUT=leaf.xml
check "rechecks a directory the command links outside" 1 "outside the workspace" \
    'ln -s "$OUT" late; echo "$X" > late/output.xml' '' \
    OUT="$outside" X="$pass_xml" CSIT_ROBOT_OUTPUT=late/output.xml
kept=1
for f in log.html report.html robot-gate.json target.xml; do
    [ "$(cat "${outside}/${f}")" = keep ] || kept=""
done
if [ -n "$kept" ] && [ ! -e "${ws}/ran" ] && [ ! -L "${ws}/leaf.xml" ] &&
    [ -z "$(find "$outside" -mindepth 1 -type d)" ] && [ ! -e "${tmp}/nowhere" ]; then
    echo "ok: nothing outside the workspace was touched"
else
    echo "FAIL: robot-output reached outside the workspace" >&2
    fail=1
fi

# A command cannot link output.xml to an older passing result elsewhere.
printf '%s\n' "$pass_xml" >"${tmp}/old-pass.xml"
check "refuses an output.xml the command links elsewhere" 1 "is a symlink" \
    'ln -s "$OLD" output.xml; exit 7' '' OLD="${tmp}/old-pass.xml"
rm -f "${ws}/output.xml"

# A command that plants robot-gate.json as a symlink cannot make the gate
# overwrite the link's target.
check "replaces a planted robot-gate.json link" 0 "" \
    'echo "$X" > output.xml; ln -s "$OUT/target.xml" robot-gate.json' '' \
    OUT="$outside" X="$pass_xml"
if [ "$(cat "${outside}/target.xml")" = keep ] && [ ! -L "${ws}/robot-gate.json" ]; then
    echo "ok: the gate did not write through a planted link"
else
    echo "FAIL: the gate wrote through a planted robot-gate.json link" >&2
    fail=1
fi

# lab.env is data: an image's JAVA_HOME must not run on the runner, and a
# value with spaces must arrive whole.
cat >"${tmp}/hostile.env" <<ENV
PROJECT_SYSTEM_IP=10.0.0.9
JAVA_HOME=/opt/\$(touch ${tmp}/pwned)/jdk
CSIT_NODE_USER=two words
ENV
check "lab.env values are not expanded" 0 "java=/opt/\$(touch ${tmp}/pwned)/jdk user=two words" \
    'echo "java=$JAVA_HOME user=$CSIT_NODE_USER" >&2' "" \
    CSIT_LAB_ENV="${tmp}/hostile.env" CSIT_ROBOT_OUTPUT=
if [ -e "${tmp}/pwned" ]; then
    echo "FAIL: lab.env ran a command substitution" >&2
    fail=1
else
    echo "ok: lab.env ran no command"
fi
printf 'A=1\nnot an assignment\n' >"${tmp}/bad.env"
check "rejects a malformed lab.env" 1 "lab.env line 2 is not NAME=VALUE" 'true' '' \
    CSIT_LAB_ENV="${tmp}/bad.env" CSIT_ROBOT_OUTPUT=

exit "$fail"
