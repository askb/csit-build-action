#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Tear down a docker CSIT lab. Best effort: teardown must never fail a job.
##############################################################################

set -u

if [ -z "${CSIT_LAB_ID:-}" ]; then
    if [ -n "${GITHUB_ENV:-}" ]; then
        # lab-up exports the ID first thing, so none means no lab in this job.
        echo "---> No CSIT lab was brought up in this job"
        exit 0
    fi
    CSIT_LAB_ID="csit-local"
fi
if [[ ! "$CSIT_LAB_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "WARNING: refusing to tear down invalid CSIT_LAB_ID '${CSIT_LAB_ID}'" >&2
    exit 0
fi
NET="csit-net-${CSIT_LAB_ID}"

echo "---> Removing CSIT lab ${CSIT_LAB_ID}"
# Match whole names: a prefix would also catch lab "${CSIT_LAB_ID}-other".
mapfile -t containers < <(docker ps -a --format '{{.Names}}' |
    grep -E "^csit-${CSIT_LAB_ID}-(node|tools)-[0-9]+\$")
if [ "${#containers[@]}" -gt 0 ]; then
    docker rm -f "${containers[@]}" || true
fi
docker network rm "$NET" >/dev/null 2>&1 || true
ssh_config="${HOME}/.ssh/config"
if [ -f "$ssh_config" ]; then
    # The same lock lab-up holds while editing, so no edit is lost. As in
    # lab-up, the pruned copy is renamed over the resolved target: lock-free
    # ssh readers never see a partial file and a symlink stays a symlink.
    exec {ssh_lock}>>"${HOME}/.ssh/csit-build-action.lock"
    flock "$ssh_lock"
    ssh_target="$(readlink -f "$ssh_config" && echo x)"
    ssh_target="${ssh_target%$'\n'x}"
    if [[ "$ssh_target" == *$'\n'* ]]; then
        echo "WARNING: ${ssh_config} resolves to a path with a line break;" \
            "its lab block is left in place" >&2
    elif tmp_config="$(mktemp "$(dirname "$ssh_target")/.csit-config.XXXXXX")"; then
        if ! { sed "/^# BEGIN csit-lab ${CSIT_LAB_ID}\$/,/^# END csit-lab ${CSIT_LAB_ID}\$/d" \
            "$ssh_target" > "$tmp_config" &&
            chmod 600 "$tmp_config" &&
            mv -f "$tmp_config" "$ssh_target"; }; then
            rm -f "$tmp_config"
        fi
    fi
    flock -u "$ssh_lock"
fi
# Derived from the validated ID, as lab-up does, rather than trusting a path.
rm -rf "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/csit-lab-${CSIT_LAB_ID}"
echo "---> CSIT lab removed"
exit 0
