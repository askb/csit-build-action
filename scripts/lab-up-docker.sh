#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Bring up a CSIT "lab" of SSH-reachable nodes as docker containers.
#
# Produces exactly the same contract the OpenStack/Heat backend produces, so
# common-functions.sh and every robot suite run unmodified:
#   slave_addresses.txt -> NUM_ODL_SYSTEM, NUM_TOOLS_SYSTEM, NUM_OPENSTACK_SYSTEM,
#                          ODL_SYSTEM_IP, ODL_SYSTEM_n_IP,
#                          TOOLS_SYSTEM_IP, TOOLS_SYSTEM_n_IP
#
# Inputs (env): ODL_NODES TOOLS_NODES CSIT_NODE_IMAGE CSIT_TOOLS_IMAGE
#               CSIT_LAB_ID WORKSPACE
##############################################################################

set -euo pipefail

ODL_NODES="${ODL_NODES:-1}"
TOOLS_NODES="${TOOLS_NODES:-0}"
CSIT_NODE_IMAGE="${CSIT_NODE_IMAGE:-ghcr.io/lfreleng-actions/csit-node:22.04-jdk21}"
CSIT_TOOLS_IMAGE="${CSIT_TOOLS_IMAGE:-ghcr.io/lfreleng-actions/csit-tools:22.04-ovs217}"
CSIT_LAB_ID="${CSIT_LAB_ID:-csit-local}"
WORKSPACE="${WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
NET="csit-net-${CSIT_LAB_ID}"
ADDRESSES="${WORKSPACE}/slave_addresses.txt"

node_user="${USER:-runner}"
key="${HOME}/.ssh/id_rsa"

echo "---> CSIT docker lab: ${ODL_NODES} odl node(s), ${TOOLS_NODES} tools node(s)"

# An ephemeral keypair the runner uses to reach every node. Reuse an existing
# id_rsa if the runner already has one so we never clobber a real key.
if [ ! -f "$key" ]; then
    mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
    ssh-keygen -t rsa -b 2048 -N "" -f "$key" -q
fi
# Nodes are ephemeral containers with fresh host keys every run.
cat >> "${HOME}/.ssh/config" <<EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ServerAliveInterval 30
EOF
chmod 600 "${HOME}/.ssh/config"

docker network create "$NET" >/dev/null 2>&1 || true

# ponytail: pull the published node image, fall back to building the bundled
# Dockerfile. Drop the fallback once the image is published to ghcr.
ensure_image() {
    local image="$1" target="${2:-node}"
    if docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    fi
    if docker pull -q "$image" >/dev/null 2>&1; then
        return 0
    fi
    local dockerfile="${CSIT_NODE_DOCKERFILE:-${GITHUB_ACTION_PATH:-$(dirname "$0")/..}/docker/Dockerfile.node}"
    echo "---> ${image} unavailable, building --target ${target} from ${dockerfile}"
    docker build -q --target "$target" -t "$image" \
        -f "$dockerfile" "$(dirname "$dockerfile")" >/dev/null
}

ensure_image "$CSIT_NODE_IMAGE" node
if [ "$TOOLS_NODES" -gt 0 ] && [ "$CSIT_TOOLS_IMAGE" != "$CSIT_NODE_IMAGE" ]; then
    ensure_image "$CSIT_TOOLS_IMAGE" tools
fi

start_node() {
    local name="$1" image="$2" role="${3:-odl}"
    local -a opts=(
        -d --name "$name" --hostname "$name" --network "$NET"
        --cap-add NET_ADMIN --cap-add SYS_PTRACE --shm-size 512m
    )
    # The tools node runs Open vSwitch on the kernel datapath and mininet,
    # which need the host's openvswitch module and full privileges. Verified
    # to work on GitHub-hosted runners (probe-tools-node.yaml).
    if [ "$role" = "tools" ]; then
        opts+=(--privileged -v /lib/modules:/lib/modules:ro)
    fi
    docker run "${opts[@]}" "$image" >/dev/null
    # The node user must match the runner's $USER: common-functions.sh calls
    # bare `ssh $IP` and robot receives -v ODL_SYSTEM_USER:$USER.
    docker exec "$name" bash -c "
        set -e
        id -u '${node_user}' >/dev/null 2>&1 || useradd -m -s /bin/bash '${node_user}'
        echo '${node_user} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/csit
        chmod 440 /etc/sudoers.d/csit
        # Robot's SSHLibrary blocks until it sees a prompt matching '>'
        # (integration/test csit/variables/Variables.py DEFAULT_LINUX_PROMPT).
        # Real CSIT VMs get this from global-jjb basic-settings.sh.
        echo 'PS1=\"[\\u@\\h \\W]> \"' >> '/home/${node_user}/.bashrc'
        install -d -m 700 -o '${node_user}' -g '${node_user}' '/home/${node_user}/.ssh'"
    docker cp "${key}.pub" "${name}:/home/${node_user}/.ssh/authorized_keys"
    docker exec "$name" bash -c "
        chown '${node_user}:${node_user}' '/home/${node_user}/.ssh/authorized_keys'
        chmod 600 '/home/${node_user}/.ssh/authorized_keys'"
    docker inspect -f "{{ (index .NetworkSettings.Networks \"${NET}\").IPAddress }}" "$name"
}

wait_for_ssh() {
    local ip="$1" i
    for i in $(seq 1 60); do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$ip" true 2>/dev/null; then
            echo "    ssh ready on ${ip}"
            return 0
        fi
        sleep 2
    done
    echo "ERROR: ssh never came up on ${ip}" >&2
    return 1
}

odl_ips=()
tools_ips=()
for i in $(seq 1 "$ODL_NODES"); do
    odl_ips+=("$(start_node "csit-${CSIT_LAB_ID}-odl-${i}" "$CSIT_NODE_IMAGE")")
done
for i in $(seq 1 "$TOOLS_NODES"); do
    tools_ips+=("$(start_node "csit-${CSIT_LAB_ID}-tools-${i}" "$CSIT_TOOLS_IMAGE" tools)")
done

: > "$ADDRESSES"
{
    echo "NUM_ODL_SYSTEM=${ODL_NODES}"
    echo "NUM_TOOLS_SYSTEM=${TOOLS_NODES}"
    # No devstack/openstack nodes in the docker backend; common-functions.sh
    # and integration-deploy-controller-run-test.sh both branch on this.
    echo "NUM_OPENSTACK_SYSTEM=0"
    echo "NUM_OPENSTACK_CONTROL_NODES=0"
    echo "NUM_OPENSTACK_COMPUTE_NODES=0"
    echo "NUM_OPENSTACK_HAPROXY_NODES=0"
    echo "ODL_SYSTEM_IP=${odl_ips[0]}"
} >> "$ADDRESSES"
for i in "${!odl_ips[@]}"; do
    echo "ODL_SYSTEM_$((i + 1))_IP=${odl_ips[$i]}" >> "$ADDRESSES"
done
if [ "$TOOLS_NODES" -gt 0 ]; then
    echo "TOOLS_SYSTEM_IP=${tools_ips[0]}" >> "$ADDRESSES"
    for i in "${!tools_ips[@]}"; do
        echo "TOOLS_SYSTEM_$((i + 1))_IP=${tools_ips[$i]}" >> "$ADDRESSES"
    done
fi

for ip in "${odl_ips[@]}" ${tools_ips[@]+"${tools_ips[@]}"}; do
    wait_for_ssh "$ip"
done

echo "---> slave_addresses.txt"
cat "$ADDRESSES"
[ -n "${GITHUB_ENV:-}" ] && cat "$ADDRESSES" >> "$GITHUB_ENV"
exit 0
