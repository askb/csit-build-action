#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Tear down a docker CSIT lab. Best effort: teardown must never fail a job.
##############################################################################

set -u

CSIT_LAB_ID="${CSIT_LAB_ID:-csit-local}"
NET="csit-net-${CSIT_LAB_ID}"

echo "---> Removing CSIT lab ${CSIT_LAB_ID}"
mapfile -t containers < <(docker ps -aq --filter "name=^csit-${CSIT_LAB_ID}-")
if [ "${#containers[@]}" -gt 0 ]; then
    docker rm -f "${containers[@]}" || true
fi
docker network rm "$NET" >/dev/null 2>&1 || true
echo "---> CSIT lab removed"
exit 0
