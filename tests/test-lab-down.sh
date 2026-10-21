#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check how scripts/lab-down-docker.sh edits ~/.ssh/config, with docker
# stubbed out: only this lab's block goes, the file is replaced by a rename
# (lock-free ssh readers never see it half written), a symlinked config stays
# a symlink and the result stays private.
#
# Usage: tests/test-lab-down.sh
##############################################################################

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
down="${PWD}/scripts/lab-down-docker.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "${tmp}/bin" "${tmp}/home/.ssh" "${tmp}/dotfiles"
printf '#!/bin/sh\nexit 0\n' >"${tmp}/bin/docker"
chmod +x "${tmp}/bin/docker"

block() {
    printf '# BEGIN csit-lab %s\nHost 10.0.0.%s\n    User u\nHost *\n# END csit-lab %s\n' \
        "$1" "$2" "$1"
}

fail=0
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
count() { grep -c "$1" "$real" || true; }

real="${tmp}/dotfiles/ssh_config"
cfg="${tmp}/home/.ssh/config"
{
    block lab1 2
    block lab2 3
    printf 'Host example\n    Port 2222\n'
} >"$real"
chmod 644 "$real"
ln -s "$real" "$cfg"
inode="$(stat -c %i "$real")"

env -i PATH="${tmp}/bin:${PATH}" HOME="${tmp}/home" RUNNER_TEMP="$tmp" \
    CSIT_LAB_ID=lab1 bash "$down" >/dev/null

check "this lab's block is removed" [ "$(count "csit-lab lab1")" -eq 0 ]
check "another lab's block is kept" [ "$(count "csit-lab lab2")" -eq 2 ]
check "the user's own entries are kept" [ "$(count "Port 2222")" -eq 1 ]
check "a symlinked config stays a symlink" [ -L "$cfg" ]
check "the target is replaced by a rename" [ "$(stat -c %i "$real")" != "$inode" ]
check "the config is private" [ "$(stat -c %a "$real")" = 600 ]
check "no temporary file is left behind" [ -z "$(find "${tmp}/dotfiles" \
    "${tmp}/home/.ssh" -name ".csit-config.*")" ]

env -i PATH="${tmp}/bin:${PATH}" HOME="${tmp}/home" RUNNER_TEMP="$tmp" \
    CSIT_LAB_ID=lab2 bash "$down" >/dev/null
check "the last lab leaves only the user's entries" \
    [ "$(cat "$real")" = "$(printf 'Host example\n    Port 2222')" ]

# readlink's output loses a trailing newline, which would name another file;
# teardown warns and still removes the lab directory.
nl="${tmp}/dotfiles/cfg"$'\n'
block lab3 4 >"$nl"
ln -sfn "$nl" "$cfg"
mkdir -p "${tmp}/csit-lab-lab3"
rc=0
env -i PATH="${tmp}/bin:${PATH}" HOME="${tmp}/home" RUNNER_TEMP="$tmp" \
    CSIT_LAB_ID=lab3 bash "$down" >"${tmp}/down.log" 2>&1 || rc=$?
check "a config path with a line break is warned about" \
    grep -q "resolves to a path with a line break" "${tmp}/down.log"
check "teardown still succeeds" [ "$rc" -eq 0 ]
check "the lab directory is still removed" [ ! -e "${tmp}/csit-lab-lab3" ]
check "the user's config is untouched" \
    [ "$(cat "$real")" = "$(printf 'Host example\n    Port 2222')" ]

exit "$fail"
