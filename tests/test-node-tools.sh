#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check that a CSIT node image carries every binary the robot suites shell out
# to over SSH.
#
# A missing one does not look like a missing tool: the suite setup dies, robot
# scores the whole suite 0 and the job just looks broken. cbench, virtualenv
# and git each cost a full debugging round trip that way -- 70 tests in one
# case -- so the list is asserted instead of rediscovered.
#
# The list comes from the suites themselves, i.e. the first word of every
# Execute_Command* / Run Command On Remote System / Run_Command_On_Controller
# call in integration-test, minus shell builtins. Note the keyword has nine
# spellings (_Should_Pass, _Passes, _At_Cwd, _At_Path, "And Log", ...); a
# regex that misses one silently under-reports.
#
# apt-get is deliberately NOT here: the only suite call is
# SSHKeywords.Install_Netstat, a fallback that never fires because netstat is
# asserted below.
#
# Usage: tests/test-node-tools.sh [image]   (default: locally built tools tag)
##############################################################################

set -euo pipefail

image="${1:-csit-tools:test}"

# ponytail: cbench is only reachable on the tools image, but the tools image is
# built FROM node, so checking tools alone covers both stages.
required=(
    awk bash cat curl git grep ip java ls mkdir mv netstat pkill ps python3 rm
    sed service ssh-keygen sudo tar unzip virtualenv wget which xz
    cbench mn ovs-ofctl ovs-vsctl
)

if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "SKIP: image ${image} not present; build it with"
    echo "  docker build --target tools -t ${image} -f docker/Dockerfile.node docker"
    exit 0
fi

missing="$(docker run --rm --entrypoint bash "${image}" -c '
    for b in '"${required[*]}"'; do
        command -v "${b}" >/dev/null 2>&1 || echo "${b}"
    done')"

if [ -n "${missing}" ]; then
    echo "FAIL: ${image} is missing:" >&2
    # shellcheck disable=SC2086  # deliberate split: one binary name per line
    printf '  %s\n' ${missing} >&2
    exit 1
fi

# virtualenv has to produce a venv with a working pip, not merely exist:
# Virtual_Env_Create runs `pip install` inside it straight afterwards.
docker run --rm --entrypoint bash "${image}" -c '
    set -e
    cd /tmp
    virtualenv v >/dev/null
    ./v/bin/pip --version >/dev/null' \
    || { echo "FAIL: virtualenv cannot build a pip-capable venv" >&2; exit 1; }

echo "PASS: ${image} carries all ${#required[@]} required binaries"
