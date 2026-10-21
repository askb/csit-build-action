#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Run each single-command step of action.yaml that launches a bundled script,
# with GITHUB_ACTION_PATH holding a space and every script stubbed. A step
# that loses the shell quotes inside its YAML scalar splits the path and
# fails to launch.
#
# Usage: tests/test-action-steps.sh
##############################################################################

set -euo pipefail
IFS=$'\n\t'

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
action="${tmp}/action path"
mkdir -p "${action}/scripts"
for name in lab-up-docker.sh run-test.sh lab-down-docker.sh; do
    printf '#!/usr/bin/env bash\ntouch "%s/ran-%s"\n' "$tmp" "$name" \
        >"${action}/scripts/${name}"
    chmod +x "${action}/scripts/${name}"
done

fail=0
mapfile -t steps < <(python3 - "${repo}/action.yaml" <<'PY'
import sys
import yaml

for step in yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]:
    run = (step.get("run") or "").strip()
    if "\n" not in run and "${GITHUB_ACTION_PATH}/scripts/" in run:
        print(f"{step['name']}\t{run}")
PY
)
if [ "${#steps[@]}" -lt 3 ]; then
    echo "FAIL: expected lab-up, run and lab-down steps, found ${#steps[@]}"
    exit 1
fi
for entry in "${steps[@]}"; do
    name="${entry%%$'\t'*}"
    run="${entry#*$'\t'}"
    if GITHUB_ACTION_PATH="$action" CSIT_BACKEND=docker \
        bash -c "$run" >/dev/null 2>&1; then
        echo "ok: ${name} launches from a path with a space"
    else
        echo "FAIL: ${name} cannot launch from a path with a space"
        fail=1
    fi
done
for name in lab-up-docker.sh run-test.sh lab-down-docker.sh; do
    if [ ! -e "${tmp}/ran-${name}" ]; then
        echo "FAIL: no step launched ${name}"
        fail=1
    fi
done

# Validate inputs refuses an env-prefix whose aliases run-test.sh would
# refuse from lab.env, after lab-up had already provisioned the lab.
validate="$(python3 - "${repo}/action.yaml" <<'PY'
import sys
import yaml

for step in yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]:
    if step.get("name") == "Validate inputs":
        print(step["run"])
PY
)"
for case in ODL:0 PROJECT:0 GITHUBX:0 TOOLS:1 GITHUB:1 RUNNER_X:1 LD:1 LD_PRELOAD:1; do
    prefix="${case%%:*}"
    rc=0
    GITHUB_ACTION_PATH="$action" MODE=lab-up CSIT_BACKEND=docker \
        PROJECT_NODES=1 TOOLS_NODES=0 NODE_IMAGE=node TOOLS_IMAGE='' \
        TOOLS_PRIVILEGED=false ENV_PREFIX="$prefix" TEST_COMMAND='' \
        ROBOT_OUTPUT='' bash -c "$validate" >/dev/null 2>&1 || rc=1
    if [ "$rc" -eq "${case#*:}" ]; then
        echo "ok: Validate inputs env-prefix ${prefix} exits ${rc}"
    else
        echo "FAIL: Validate inputs env-prefix ${prefix} exits ${rc}"
        fail=1
    fi
done

rcs=""
for out in output.xml $'nl\n/output.xml' $'nl\r/output.xml'; do
    rc=0
    GITHUB_ACTION_PATH="$action" MODE=run CSIT_BACKEND=docker \
        PROJECT_NODES=1 TOOLS_NODES=0 NODE_IMAGE=node TOOLS_IMAGE='' \
        TOOLS_PRIVILEGED=false ENV_PREFIX=ODL TEST_COMMAND=true \
        ROBOT_OUTPUT="$out" bash -c "$validate" >/dev/null 2>&1 || rc=1
    rcs="${rcs}${rc}"
done
if [ "$rcs" = "011" ]; then
    echo "ok: Validate inputs refuses a line break in robot-output"
else
    echo "FAIL: Validate inputs robot-output line breaks exit ${rcs}"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "PASS: action steps quote the action path"
