#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check scripts/lab-up-docker.sh with docker and ssh stubbed out: a supplied
# lab ID reaches GITHUB_ENV before anything is created, so a later lab-down
# step can tear down a half-built lab, and the lab's ssh block pins the port
# the bundled sshd listens on.
#
# Usage: tests/test-lab-up.sh
##############################################################################

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
up="${PWD}/scripts/lab-up-docker.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "${tmp}/bin" "${tmp}/home/.ssh"
# Answers just enough of the docker CLI for lab-up to provision one node;
# STUB_FAIL_RUN makes `docker run` fail, as a missing image would.
cat >"${tmp}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "run "*) [ -z "${STUB_FAIL_RUN:-}" ] || exit 1 ;;
    "inspect "*) echo 172.18.0.5 ;;
    "exec "*)
        case "$*" in
            *"getent passwd"*) echo "u:x:1000:1000::/home/u:/bin/bash" ;;
            *"id -gn"*) echo u ;;
            *ssh_host_ed25519_key.pub*) echo "ssh-ed25519 AAAAstub root@node" ;;
        esac ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"${tmp}/bin/ssh"
chmod +x "${tmp}/bin/docker" "${tmp}/bin/ssh"
printf 'Host *\n    Port 2222\n    ProxyJump bastion.example\n    RemoteCommand tmux\n' \
    >"${tmp}/home/.ssh/config"

fail=0
pin="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# $1 name, then the command whose success means the check passed
check() {
    local name="$1"
    shift
    if "$@"; then
        echo "ok: ${name}"
    else
        echo "FAIL: ${name}" >&2
        fail=1
    fi
}

lab_up() {
    env -i PATH="${tmp}/bin:${PATH}" HOME="${tmp}/home" USER=u \
        RUNNER_TEMP="$tmp" GITHUB_ENV="${tmp}/ghenv" CSIT_NODE_IMAGE="node@${pin}" \
        "$@" bash "$up" >"${tmp}/out.log" 2>&1
}

: >"${tmp}/ghenv"
rc=0
lab_up CSIT_LAB_ID=given STUB_FAIL_RUN=1 || rc=$?
check "a failed lab-up still fails" [ "$rc" -ne 0 ]
check "a supplied lab ID reaches GITHUB_ENV for lab-down" \
    grep -qx "CSIT_LAB_ID=given" "${tmp}/ghenv"

: >"${tmp}/ghenv"
rc=0
lab_up CSIT_LAB_ID=lab1 || rc=$?
check "lab-up succeeds against the stubs" [ "$rc" -eq 0 ]
block="$(sed -n '/^# BEGIN csit-lab lab1$/,/^# END csit-lab lab1$/p' \
    "${tmp}/home/.ssh/config")"
check "the lab block pins the sshd port" grep -qx "    Port 22" <<<"$block"
check "the lab block comes before the user's Host *" \
    [ "$(head -n 1 "${tmp}/home/.ssh/config")" = "# BEGIN csit-lab lab1" ]
lab_ip="$(sed -n 's/^Host \([0-9.]*\).*/\1/p' <<<"$block")"
lab_opts="$(ssh -F "${tmp}/home/.ssh/config" -G "$lab_ip" 2>/dev/null)"
# shellcheck disable=SC2329 # run through check
not_redirected() { ! grep -qiE '^(proxyjump|remotecommand) ' <<<"$lab_opts"; }
check "a user's Host * cannot proxy or redirect lab sessions" not_redirected
check "lab.env is published" grep -qx "PROJECT_SYSTEM_IP=172.18.0.5" "${tmp}/ghenv"

# An earlier lab's names stay in GITHUB_ENV, so the ones this lab does not
# set are emptied rather than left pointing at the old lab.
: >"${tmp}/ghenv"
lab_up CSIT_LAB_ID=lab5 \
    CSIT_LAB_VARS="NUM_PROJECT_SYSTEM CSIT_NODE_JAVA_HOME TOOLS_SYSTEM_IP ODL_SYSTEM_IP *"
check "a stale JDK path is emptied" grep -qx "CSIT_NODE_JAVA_HOME=" "${tmp}/ghenv"
check "a stale tools IP is emptied" grep -qx "TOOLS_SYSTEM_IP=" "${tmp}/ghenv"
check "a stale prefix alias is emptied" grep -qx "ODL_SYSTEM_IP=" "${tmp}/ghenv"
check "a name this lab sets is kept" grep -qx "NUM_PROJECT_SYSTEM=1" "${tmp}/ghenv"
# shellcheck disable=SC2329 # run through check
lacks() { ! grep -qx -- "$1" "${tmp}/ghenv"; }
check "a name this lab sets is not emptied" lacks "NUM_PROJECT_SYSTEM="
check "a malformed name is ignored" lacks "\*="
check "this lab's names are recorded" grep -qE \
    "^CSIT_LAB_VARS=NUM_PROJECT_SYSTEM .*CSIT_NODE_USER$" "${tmp}/ghenv"

# readlink's output loses a trailing newline, which would name another file.
mv "${tmp}/home/.ssh/config" "${tmp}/home/.ssh/real"$'\n'
ln -s "${tmp}/home/.ssh/real"$'\n' "${tmp}/home/.ssh/config"
rc=0
lab_up CSIT_LAB_ID=lab6 || rc=$?
check "a config path with a line break is refused" \
    grep -q "resolves to a path with a line break" "${tmp}/out.log"
check "a config path with a line break fails lab-up" [ "$rc" -ne 0 ]
rm "${tmp}/home/.ssh/config"
mv "${tmp}/home/.ssh/real"$'\n' "${tmp}/home/.ssh/config"

# A tag can move between runs, so only a digest or image ID is accepted.
rc=0
lab_up CSIT_LAB_ID=lab3 CSIT_NODE_IMAGE=node:latest || rc=$?
check "an unpinned image is refused" grep -q "must be pinned" "${tmp}/out.log"
check "an unpinned image fails lab-up" [ "$rc" -ne 0 ]
rc=0
lab_up CSIT_LAB_ID=lab4 CSIT_NODE_IMAGE="${pin}" || rc=$?
check "a local image ID is accepted" [ "$rc" -eq 0 ]

# A prefix whose aliases run-test.sh would refuse fails before any node.
for prefix in GITHUB RUNNER_X LD LD_PRELOAD; do
    rc=0
    lab_up CSIT_LAB_ID=lab2 CSIT_ENV_PREFIX="$prefix" || rc=$?
    check "env-prefix ${prefix} is refused" \
        grep -q "not start with GITHUB, RUNNER or LD" "${tmp}/out.log"
    check "env-prefix ${prefix} fails lab-up" [ "$rc" -ne 0 ]
done

if [ "$fail" -ne 0 ]; then
    sed 's/^/    /' "${tmp}/out.log" >&2
fi
exit "$fail"
