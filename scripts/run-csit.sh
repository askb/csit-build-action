#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Run one CSIT job.
#
# Deliberately does NOT reimplement the CSIT logic. It stages the environment
# that releng/builder's own scripts expect, then executes those scripts
# unmodified, so builder stays the single source of truth:
#   integration-install-robotframework.sh
#   common-functions.sh
#   integration-deploy-controller-run-test.sh   (1 node)
#   integration-start-cluster-run-test.sh       (3 node)
#
# Inputs (env): CSIT_SCRIPTS_DIR  jjb/integration of a checked-out builder
#               CSIT_LF_ENV       path to global-jjb jenkins-init-scripts/lf-env.sh
#               WORKSPACE         holds test/ (integration/test checkout)
#               plus every CSIT parameter (see the JJB job templates)
##############################################################################

set -eu

CSIT_SCRIPTS_DIR="${CSIT_SCRIPTS_DIR:?path to builder jjb/integration required}"
# ponytail: WORKSPACE is Jenkins' name for what GHA calls GITHUB_WORKSPACE, and
# builder's scripts read WORKSPACE, so bridge the two rather than patch them.
WORKSPACE="${WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
export WORKSPACE
CSIT_LF_ENV="${CSIT_LF_ENV:-${CSIT_SCRIPTS_DIR}/../global-jjb/jenkins-init-scripts/lf-env.sh}"

cd "$WORKSPACE"

echo "=================================================="
echo "  Staging environment for builder's CSIT scripts"
echo "=================================================="

# builder scripts source ~/lf-env.sh unconditionally.
cp "$CSIT_LF_ENV" "${HOME}/lf-env.sh"

# Jenkins `inject` steps become plain sourcing here.
# shellcheck disable=SC1091
. "${WORKSPACE}/slave_addresses.txt"
set -a
# shellcheck disable=SC1091
. "${WORKSPACE}/slave_addresses.txt"
set +a
export NUM_ODL_SYSTEM NUM_TOOLS_SYSTEM NUM_OPENSTACK_SYSTEM

echo "---> integration-install-robotframework.sh"
bash "${CSIT_SCRIPTS_DIR}/integration-install-robotframework.sh"
set -a
# shellcheck disable=SC1091
. "${WORKSPACE}/env.properties"
set +a
echo "ROBOT_VENV=${ROBOT_VENV}"

# Replaces copy-common-functions.sh, which discovers nodes via `openstack stack
# show`. Node discovery already happened in the lab-up step, so just use it.
echo "---> distributing common-functions.sh"
cp "${CSIT_SCRIPTS_DIR}/common-functions.sh" /tmp/common-functions.sh
for var in $(compgen -A variable | grep -E '^(ODL|TOOLS)_SYSTEM_[0-9]+_IP$'); do
    ip="${!var}"
    echo "    -> ${ip}"
    scp -q /tmp/common-functions.sh "${ip}:/tmp/"
done

echo "=================================================="
echo "  Running CSIT"
echo "=================================================="
if [ "${NUM_ODL_SYSTEM}" -gt 1 ]; then
    # The 3node JJB template runs configure-clustering before the test; the
    # 1node template folds the equivalent into deploy-controller-run-test.
    echo "---> integration-configure-clustering.sh"
    bash "${CSIT_SCRIPTS_DIR}/integration-configure-clustering.sh"
    runner="integration-start-cluster-run-test.sh"
else
    runner="integration-deploy-controller-run-test.sh"
fi
echo "---> ${runner}"
bash "${CSIT_SCRIPTS_DIR}/${runner}"

# builder's run scripts end the robot call with `|| true`: on Jenkins the build
# result comes from the Robot plugin parsing output.xml against the
# robot-pass/unstable-threshold job parameters, not from the shell exit code.
# GHA has no such plugin, so apply the same thresholds here.
echo "---> robot result gate (pass>=${ROBOT_PASS_THRESHOLD:-100.0}%)"
python3 "$(dirname "${BASH_SOURCE[0]}")/robot-gate.py" \
    "${WORKSPACE}/output.xml" \
    "${ROBOT_PASS_THRESHOLD:-100.0}" "${ROBOT_UNSTABLE_THRESHOLD:-0.0}"
