#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Run a project's CSIT test command against a lab brought up by lab-up.
#
# The action knows nothing about the project's harness: the caller's test
# command does the deploying and testing, given the lab's node addresses
# (lab.env), the resolved artifact (ARTIFACT_*) and its own extra-env.
#
# Inputs (env):
#   CSIT_TEST_COMMAND   bash command line, run in GITHUB_WORKSPACE
#   CSIT_EXTRA_ENV      KEY=VALUE lines set for the command alone; blank lines
#                       and '#' comments are skipped
#   CSIT_LAB_ENV        lab.env written by lab-up
#   CSIT_ROBOT_OUTPUT   Robot Framework output.xml, relative to the
#                       workspace; empty means the command's exit status is
#                       the verdict
#   ROBOT_PASS_THRESHOLD ROBOT_UNSTABLE_THRESHOLD CSIT_JOB  for the gate
##############################################################################

set -euo pipefail

CSIT_TEST_COMMAND="${CSIT_TEST_COMMAND:?test-command is required}"
CSIT_LAB_ENV="${CSIT_LAB_ENV:?CSIT_LAB_ENV not set; run lab-up first}"
CSIT_ROBOT_OUTPUT="${CSIT_ROBOT_OUTPUT-output.xml}"
WORKSPACE="${WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${script_dir}/robot-gate.py"

# Names whose value changes how the shell, the loader or the runner behave,
# or that this script provides; a test command that really needs a different
# value can set it itself.
denied() {
    case "$1" in
        PATH|IFS|HOME|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|PS4|LD_*|GITHUB_*|RUNNER_*|\
        WORKSPACE|CSIT_ACTION_PATH)
            return 0 ;;
    esac
    return 1
}

# Reads NAME=VALUE lines from stdin into the array named $2, as data: a
# value is never expanded, so a line in lab.env (which carries the image's
# JAVA_HOME) or extra-env cannot run commands. Blank lines and '#' comments
# are skipped; $1 labels errors.
read_assignments() {
    local label="$1" line name n=0
    local -n into="$2"
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        name="${line%%=*}"
        if [ "$name" = "$line" ] || [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "ERROR: ${label} line ${n} is not NAME=VALUE" >&2
            exit 1
        fi
        if denied "$name"; then
            echo "ERROR: ${label} may not set ${name}" >&2
            exit 1
        fi
        into+=("${name}=${line#*=}")
    done
}

# GITHUB_ENV already carries lab.env into this step; loading it again makes
# the script usable outside Actions and wins over a stale earlier lab.
lab_env=()
read_assignments lab.env lab_env <"$CSIT_LAB_ENV"
for assignment in ${lab_env[@]+"${lab_env[@]}"}; do
    export "${assignment?}"
done

# Applied to the test command alone, so an entry cannot change this script's
# own variables, such as the gate path or the robot-output check.
extra_env=()
read_assignments extra-env extra_env <<<"${CSIT_EXTRA_ENV:-}"

export WORKSPACE
export CSIT_ACTION_PATH="${CSIT_ACTION_PATH:-$(dirname "$script_dir")}"

cd "$WORKSPACE"
if [ -n "$CSIT_ROBOT_OUTPUT" ]; then
    # A command that dies before writing results must not leave a previous
    # run's output for the gate to approve.
    "${script_dir}/clear-results.sh" "$CSIT_ROBOT_OUTPUT"
fi

echo "---> test command"
rc=0
env ${extra_env[@]+"${extra_env[@]}"} bash -c "$CSIT_TEST_COMMAND" || rc=$?

if [ -z "$CSIT_ROBOT_OUTPUT" ]; then
    [ "$rc" -eq 0 ] || echo "ERROR: test command exited ${rc}" >&2
    exit "$rc"
fi
if [ "$rc" -ne 0 ]; then
    # Robot exits non-zero for any failed test, and the thresholds exist to
    # tolerate some, so the gate decides.
    echo "::warning::test command exited ${rc}; robot results decide the verdict"
fi
# The command may have created the output directory; the gate writes beside
# output.xml, so it must still resolve inside the workspace.
"${script_dir}/clear-results.sh" --check-only "$CSIT_ROBOT_OUTPUT"
echo "---> robot result gate (pass>=${ROBOT_PASS_THRESHOLD:-100.0}%)"
python3 "$gate" "$CSIT_ROBOT_OUTPUT" \
    "${ROBOT_PASS_THRESHOLD:-100.0}" "${ROBOT_UNSTABLE_THRESHOLD:-0.0}"
