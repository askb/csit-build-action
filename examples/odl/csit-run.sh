#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# OpenDaylight CSIT test command for csit-build-action.
#
# Use as the action's test-command with env-prefix: ODL, so lab-up publishes
# the controller nodes as NUM_ODL_SYSTEM / ODL_SYSTEM_n_IP:
#   test-command: '"$CSIT_ACTION_PATH/examples/odl/csit-run.sh"'
#
# Deliberately does NOT reimplement the CSIT logic. It stages the environment
# that releng/builder's own scripts expect, then executes those scripts
# unmodified, so builder stays the single source of truth:
#   integration-install-robotframework.sh
#   common-functions.sh
#   integration-configure-clustering.sh         (3 node)
#   integration-deploy-controller-run-test.sh   (1 node)
#   integration-start-cluster-run-test.sh       (3 node)
#
# Inputs (env, mostly through the action's extra-env):
#   CSIT_SCRIPTS_DIR  jjb/integration of a checked-out builder
#   CSIT_LF_ENV       global-jjb jenkins-init-scripts/lf-env.sh
#   CSIT_NODE_JAVA_HOME  the nodes' JDK, from lab-up
#   CSIT_TEST_DIR     integration/test checkout (default: test)
#   ARTIFACT_*        the karaf distribution, from the action's resolver
#   plus the JJB job parameters builder's scripts read: DISTROSTREAM,
#   DISTROBRANCH, KARAF_VERSION, JDKVERSION, TESTPLAN, SUITES, TESTOPTIONS,
#   CONTROLLER* and so on (see README.md in this directory).
##############################################################################

set -eu

CSIT_SCRIPTS_DIR="${CSIT_SCRIPTS_DIR:?path to builder jjb/integration required}"
# WORKSPACE is Jenkins' name for what GHA calls GITHUB_WORKSPACE, and
# builder's scripts read WORKSPACE, so bridge the two rather than patch them.
WORKSPACE="${WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
export WORKSPACE
CSIT_LF_ENV="${CSIT_LF_ENV:?path to global-jjb jenkins-init-scripts/lf-env.sh required}"
# builder's scripts run ${JAVA_HOME}/bin/java and jstack on the nodes.
JAVA_HOME="${CSIT_NODE_JAVA_HOME:?the node image has no JDK at its JAVA_HOME}"
export JAVA_HOME
CSIT_LAB_DIR="${CSIT_LAB_DIR:?CSIT_LAB_DIR not set; run lab-up first}"

# builder has 1node and 3node templates; the 3node runner always addresses
# ODL_SYSTEM_3_IP.
case "${NUM_ODL_SYSTEM:-}" in
    1|3) ;;
    *)
        echo "ERROR: needs env-prefix ODL and project-nodes 1 or 3" \
             "(NUM_ODL_SYSTEM='${NUM_ODL_SYSTEM:-}')" >&2
        exit 1 ;;
esac
NUM_TOOLS_SYSTEM="${NUM_TOOLS_SYSTEM:-0}"
# No devstack nodes here; common-functions.sh and the runners branch on these.
export NUM_OPENSTACK_SYSTEM=0 NUM_OPENSTACK_CONTROL_NODES=0 \
    NUM_OPENSTACK_COMPUTE_NODES=0 NUM_OPENSTACK_HAPROXY_NODES=0

# The distribution, under the names builder's integration-set-variables.sh
# would have injected. The project is the Maven group's last component:
# .../org/opendaylight/<project>/<artifact>/<version>/<file>.
ARTIFACT_URL="${ARTIFACT_URL:?no artifact resolved; set artifact-url or the Maven inputs}"
ACTUAL_BUNDLE_URL="$ARTIFACT_URL"
BUNDLE_URL="${BUNDLE_URL:-$ARTIFACT_URL}"
BUNDLE="$ARTIFACT_FILE"
BUNDLE_VERSION="$ARTIFACT_VERSION"
BUNDLEFOLDER="$ARTIFACT_FOLDER"
KARAF_PROJECT="${KARAF_PROJECT:-$(basename "$(dirname "$(dirname "$(dirname "$ARTIFACT_URL")")")")}"
KARAF_VERSION="${KARAF_VERSION:-karaf4}"
# The artifact's own repository host, not a fixed ODL Nexus.
NEXUSURL_PREFIX="${NEXUSURL_PREFIX:-$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$ARTIFACT_URL")}"
DISTROBRANCH="${DISTROBRANCH:-master}"
GERRIT_PROJECT="${GERRIT_PROJECT:-integration/test}"
GERRIT_BRANCH="${GERRIT_BRANCH:-$DISTROBRANCH}"
GERRIT_REFSPEC="${GERRIT_REFSPEC:-refs/heads/${GERRIT_BRANCH}}"
export ACTUAL_BUNDLE_URL BUNDLE_URL BUNDLE BUNDLE_VERSION BUNDLEFOLDER \
    KARAF_PROJECT KARAF_VERSION NEXUSURL_PREFIX DISTROBRANCH \
    GERRIT_PROJECT GERRIT_BRANCH GERRIT_REFSPEC NUM_ODL_SYSTEM NUM_TOOLS_SYSTEM

# The JJB job parameters every CSIT job sets, with the CSIT templates'
# defaults for the optional ones.
: "${DISTROSTREAM:?DISTROSTREAM (the stream suites branch on) is required}"
: "${TESTPLAN:?TESTPLAN (the fallback robot test plan) is required}"
CONTROLLERSCOPE="${CONTROLLERSCOPE:-only}"
# builder's common-functions.sh sets CONTROLLERMEM from CONTROLLERMAXMEM, so
# a CONTROLLERMEM given alone becomes the max for it to reach the controller.
CONTROLLERMAXMEM="${CONTROLLERMAXMEM:-${CONTROLLERMEM:-2048m}}"
CONTROLLERMEM="$CONTROLLERMAXMEM"
USEFEATURESBOOT="${USEFEATURESBOOT:-True}"
ELASTICSEARCHATTRIBUTE="${ELASTICSEARCHATTRIBUTE:-disabled}"
IS_KARAF_APPL="${IS_KARAF_APPL:-True}"
export DISTROSTREAM TESTPLAN CONTROLLERSCOPE CONTROLLERMAXMEM CONTROLLERMEM \
    USEFEATURESBOOT ELASTICSEARCHATTRIBUTE IS_KARAF_APPL

cd "$WORKSPACE"

# builder's get_test_suites reads ${WORKSPACE}/test/csit, so expose any other
# checkout location there, never replacing something already in place.
test_src="$(realpath -m "${CSIT_TEST_DIR:-test}")"
if [ "$test_src" != "$(realpath -m "${WORKSPACE}/test")" ]; then
    if [ -e "${WORKSPACE}/test" ]; then
        echo "ERROR: test-dir ${CSIT_TEST_DIR} given but ${WORKSPACE}/test" \
             "already exists" >&2
        exit 1
    fi
    ln -s "$test_src" "${WORKSPACE}/test"
fi
if [ ! -d "${WORKSPACE}/test/csit" ]; then
    echo "ERROR: no integration/test checkout at ${test_src}" >&2
    exit 1
fi

echo "=================================================="
echo "  Staging environment for builder's CSIT scripts"
echo "=================================================="

# builder's scripts source the shared paths ~/lf-env.sh and
# /tmp/common-functions.sh, so concurrent jobs on one self-hosted machine would
# swap each other's revision mid-run. Hold a host-wide lock from the first copy
# until the runner ends.
exec {csit_lock}>>/tmp/csit-build-action.lock
if ! flock -n "$csit_lock"; then
    echo "    waiting for another CSIT run on this host to finish"
    flock "$csit_lock"
fi

# builder scripts source ~/lf-env.sh unconditionally. Put back whatever was
# there before once builder's scripts are done, including on failure.
lf_env="${HOME}/lf-env.sh"
lf_env_backup=""
if [ -e "$lf_env" ] || [ -L "$lf_env" ]; then
    lf_env_backup="$(mktemp "${HOME}/.lf-env.sh.csit.XXXXXX")"
    mv -f "$lf_env" "$lf_env_backup"
fi
restore_lf_env() {
    rm -f "$lf_env"
    if [ -n "$lf_env_backup" ]; then
        mv -f "$lf_env_backup" "$lf_env"
        lf_env_backup=""
    fi
}
lab_alias=""
on_exit() {
    restore_lf_env
    if [ -n "$lab_alias" ]; then
        rm -rf "$lab_alias"
    fi
}
trap on_exit EXIT
cp "$CSIT_LF_ENV" "$lf_env"

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
# Only the current counts: GITHUB_ENV can still carry a previous lab's nodes.
node_vars=()
for i in $(seq 1 "${NUM_ODL_SYSTEM}"); do node_vars+=("ODL_SYSTEM_${i}_IP"); done
for i in $(seq 1 "${NUM_TOOLS_SYSTEM}"); do node_vars+=("TOOLS_SYSTEM_${i}_IP"); done
for var in "${node_vars[@]}"; do
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
    # configure-clustering derives the feature list in its own shell, but the
    # cluster runner's post-startup script installs SPACE_SEPARATED_FEATURES
    # when features-boot is off. Derive it again in a separate shell, since
    # builder's helpers do not survive this script's set -u.
    mapfile -t features < <(bash -c '
        . /tmp/common-functions.sh "$BUNDLEFOLDER" "$DISTROSTREAM" >&2
        get_features >&2
        printf "%s\n" "$ACTUALFEATURES" "$SPACE_SEPARATED_FEATURES"')
    if [ "${#features[@]}" -ne 2 ] || [ -z "${features[0]}" ]; then
        echo "ERROR: could not derive the cluster feature list" >&2
        exit 1
    fi
    ACTUALFEATURES="${features[0]}"
    SPACE_SEPARATED_FEATURES="${features[1]}"
    export ACTUALFEATURES SPACE_SEPARATED_FEATURES
    runner="integration-start-cluster-run-test.sh"
else
    runner="integration-deploy-controller-run-test.sh"
fi
# The runners pass ODL/TOOLS_SYSTEM_USER but not DEFAULT_USER, which
# Variables.py sets to jenkins and Utils' SSH helpers fall back to. Put it
# first so a caller's own TESTOPTIONS can still override it.
# Suites that log in with a key read ${USER_HOME}/.ssh/${SSH_KEY}. The runners
# pass USER_HOME as $HOME, but later -v options win, so point both at the
# lab's own key. A few suites hard-code id_rsa; paramiko detects the key type
# from the file, so a link with that name is enough.
ln -sf id_ed25519 "${CSIT_LAB_DIR}/.ssh/id_rsa"
# The runners expand ${TESTOPTIONS} unquoted, so whitespace in the lab path
# would split it into extra robot arguments; quotes inside the value do not
# survive that. Point robot at a whitespace-free link to the lab instead.
robot_home="$CSIT_LAB_DIR"
if [[ "$robot_home" =~ [[:space:]] ]]; then
    lab_alias="$(mktemp -d /tmp/csit-lab.XXXXXX)"
    ln -s "$CSIT_LAB_DIR" "${lab_alias}/lab"
    robot_home="${lab_alias}/lab"
fi
TESTOPTIONS="-v DEFAULT_USER:${USER:-runner} ${TESTOPTIONS:-}"
TESTOPTIONS+=" -v USER_HOME:${robot_home} -v SSH_KEY:id_ed25519"
export TESTOPTIONS
echo "---> ${runner}"
bash "${CSIT_SCRIPTS_DIR}/${runner}"
on_exit
# A second restore on exit would delete the file just put back, or another
# run's staged copy once the lock is released.
trap - EXIT
flock -u "$csit_lock"
# builder ends robot with `|| true`; the action's gate judges output.xml
# against robot-pass-threshold, as the Jenkins Robot plugin did.
