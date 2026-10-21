#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Bring up a CSIT "lab" of SSH-reachable nodes as docker containers.
#
# The lab is described to the test command in ${CSIT_LAB_DIR}/lab.env, which
# is also appended to GITHUB_ENV:
#   NUM_PROJECT_SYSTEM, PROJECT_SYSTEM_IP, PROJECT_SYSTEM_n_IP,
#   NUM_TOOLS_SYSTEM, TOOLS_SYSTEM_IP, TOOLS_SYSTEM_n_IP,
#   CSIT_LAB_DIR, CSIT_SSH_KEY, CSIT_NODE_USER, and CSIT_NODE_JAVA_HOME when
#   the node image has a JDK at its JAVA_HOME. A node path, it is not named
#   JAVA_HOME so later steps keep the runner's own. CSIT_LAB_VARS lists these
#   names, so a later lab in the job empties the ones it does not set.
# With CSIT_ENV_PREFIX=FOO the project nodes are also published as
# NUM_FOO_SYSTEM, FOO_SYSTEM_IP and FOO_SYSTEM_n_IP, the names a project's
# existing harness already reads.
#
# Inputs (env): PROJECT_NODES TOOLS_NODES CSIT_NODE_IMAGE CSIT_TOOLS_IMAGE
#               CSIT_TOOLS_PRIVILEGED CSIT_ENV_PREFIX CSIT_NODE_PROMPT
#               CSIT_LAB_ID
#               CSIT_LAB_ID is optional: on GHA a unique one is allocated.
#               Either way it is exported via GITHUB_ENV so lab-down in the
#               same job finds it.
#               CSIT_NODE_PROMPT, when set, becomes PS1 for the node user, for
#               harnesses that wait for a particular shell prompt.
#
# The images are never built here: the caller names them, ideally pinned by
# digest, and they are used if present locally or pulled.
#
# Every lab gets a private directory (CSIT_LAB_DIR) holding its own ed25519
# client key and a known_hosts built from each container's freshly generated
# host key, so SSH to the nodes is strictly host-key checked and the runner's
# own keys are never read or written.
#
# Under Actions it also sets the step outputs project-system-ip and
# lab-env-file.
##############################################################################

set -euo pipefail
# start_node runs inside $(...), where bash otherwise drops errexit and would
# hand back the IP of a half-provisioned node.
shopt -s inherit_errexit

PROJECT_NODES="${PROJECT_NODES:-1}"
TOOLS_NODES="${TOOLS_NODES:-0}"
CSIT_ENV_PREFIX="${CSIT_ENV_PREFIX:-PROJECT}"
CSIT_NODE_PROMPT="${CSIT_NODE_PROMPT:-}"
CSIT_NODE_IMAGE="${CSIT_NODE_IMAGE:-}"
CSIT_TOOLS_IMAGE="${CSIT_TOOLS_IMAGE:-}"
CSIT_TOOLS_PRIVILEGED="${CSIT_TOOLS_PRIVILEGED:-false}"
if [[ ! "$PROJECT_NODES" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: project-nodes must be an integer >= 1, got '${PROJECT_NODES}'" >&2
    exit 1
fi
if [[ ! "$TOOLS_NODES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: tools-nodes must be an integer >= 0, got '${TOOLS_NODES}'" >&2
    exit 1
fi
# run-test.sh refuses GITHUB_*, RUNNER_* and LD_* names from lab.env.
if [[ ! "$CSIT_ENV_PREFIX" =~ ^[A-Z][A-Z0-9_]*$ ]] || [ "$CSIT_ENV_PREFIX" = "TOOLS" ] \
    || [[ "$CSIT_ENV_PREFIX" =~ ^(GITHUB|RUNNER|LD)(_|$) ]]; then
    echo "ERROR: env-prefix must match [A-Z][A-Z0-9_]*, not be TOOLS" \
        "and not start with GITHUB, RUNNER or LD" >&2
    exit 1
fi
if [ -z "$CSIT_NODE_IMAGE" ]; then
    echo "ERROR: node-image (CSIT_NODE_IMAGE) is required" >&2
    exit 1
fi
if [ "$TOOLS_NODES" -gt 0 ] && [ -z "$CSIT_TOOLS_IMAGE" ]; then
    echo "ERROR: tools-image (CSIT_TOOLS_IMAGE) is required when tools-nodes > 0" >&2
    exit 1
fi
case "$CSIT_TOOLS_PRIVILEGED" in
    true|false) ;;
    *)
        echo "ERROR: tools-privileged must be true or false" >&2
        exit 1
        ;;
esac
if [ -z "${CSIT_LAB_ID:-}" ]; then
    if [ -n "${GITHUB_ENV:-}" ]; then
        # Every job in a run shares run_id/run_attempt, matrix instances
        # included; the random suffix keeps labs on a shared daemon apart.
        suffix="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
        CSIT_LAB_ID="${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}-${suffix}"
    else
        CSIT_LAB_ID="csit-local"
    fi
fi
# The ID ends up in container names and a sed address in lab-down.
if [[ ! "$CSIT_LAB_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "ERROR: CSIT_LAB_ID '${CSIT_LAB_ID}' must match [A-Za-z0-9_-]+" >&2
    exit 1
fi
# Exported before anything is created, generated or supplied, so a lab-down
# step that only inherits GITHUB_ENV can find a half-built lab.
[ -n "${GITHUB_ENV:-}" ] && echo "CSIT_LAB_ID=${CSIT_LAB_ID}" >>"$GITHUB_ENV"
NET="csit-net-${CSIT_LAB_ID}"
CSIT_LAB_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/csit-lab-${CSIT_LAB_ID}"
# The ssh config quotes these paths, which handles spaces; ssh has no escape
# for a double quote and expands % tokens, so those cannot be written safely.
case "$CSIT_LAB_DIR" in
    *'"'* | *%* | *$'\n'*)
        echo "ERROR: lab directory '${CSIT_LAB_DIR}' contains '\"', '%' or a" \
            "line break; set RUNNER_TEMP to a plain path" >&2
        exit 1 ;;
esac
LAB_ENV="${CSIT_LAB_DIR}/lab.env"
[ -n "${GITHUB_ENV:-}" ] && echo "CSIT_LAB_DIR=${CSIT_LAB_DIR}" >>"$GITHUB_ENV"

node_user="${USER:-runner}"
key="${CSIT_LAB_DIR}/.ssh/id_ed25519"
known_hosts="${CSIT_LAB_DIR}/.ssh/known_hosts"

echo "---> CSIT docker lab: ${PROJECT_NODES} project node(s), ${TOOLS_NODES} tools node(s)"

# -p: a concurrent job may create it first. HOME exists, so only .ssh can be
# created and take the mode.
# shellcheck disable=SC2174
mkdir -p -m 700 "${HOME}/.ssh"
# Runner services sharing one account share ~/.ssh: key creation and the
# config edits here and in lab-down all hold this lock.
exec {ssh_lock}>>"${HOME}/.ssh/csit-build-action.lock"

# A keypair private to this lab. A stale directory from an earlier lab with
# the same ID (local runs reuse csit-local) is replaced, never trusted.
rm -rf "$CSIT_LAB_DIR"
mkdir -m 700 "$CSIT_LAB_DIR" "${CSIT_LAB_DIR}/.ssh"
ssh-keygen -t ed25519 -N "" -C "csit-lab-${CSIT_LAB_ID}" -f "$key" -q
: > "$known_hosts"
# IPv6 is disabled per-interface inside a container on an IPv4-only docker
# network, so `ip -6 addr add` fails with "IPv6 is disabled on this device".
# Suites that assign their own IPv6 address to a node then fail; for
# example, OpenDaylight's bgp_ipv6_basic.robot adds 2607:f0d0:1002:11::2/64
# to the tools node to peer exabgp over it. The subnet below is only there
# to turn the feature on: it is a ULA that no suite refers to, and nodes
# keep addressing each other over IPv4. Each lab draws its own /64, since
# concurrent labs on one daemon cannot share an address pool.
net_ok=""
for _ in 1 2 3 4 5; do
    subnet="fd00:c517:$(od -An -N2 -tx2 /dev/urandom | tr -d ' \n')::/64"
    if docker network create --ipv6 --subnet "$subnet" "$NET" >/dev/null 2>&1; then
        net_ok=1
        break
    fi
done
if [ -z "$net_ok" ]; then
    docker network create "$NET" >/dev/null 2>&1 || true
    if ! docker network inspect "$NET" --format '{{.EnableIPv6}}' 2>/dev/null | grep -q true; then
        echo "::warning::docker network $NET has no IPv6;" \
             "IPv6 suites such as bgp_ipv6_basic will fail to assign addresses"
    fi
fi

ensure_image() {
    local image="$1" pin='sha256:[0-9a-f]{64}$'
    # A tag can move, or name an unaudited local build; a digest or image ID
    # names fixed bits, so a local copy of one is safe to reuse.
    if [[ ! "$image" =~ @${pin} && ! "$image" =~ ^${pin} ]]; then
        echo "ERROR: ${image} must be pinned: name@sha256:<digest> or an image ID" >&2
        return 1
    fi
    if docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    fi
    if ! docker pull -q "$image" >/dev/null; then
        echo "ERROR: cannot pull ${image}" >&2
        return 1
    fi
}

ensure_image "$CSIT_NODE_IMAGE"
if [ "$TOOLS_NODES" -gt 0 ] && [ "$CSIT_TOOLS_IMAGE" != "$CSIT_NODE_IMAGE" ]; then
    ensure_image "$CSIT_TOOLS_IMAGE"
fi

# Handed on only if the image declares a JAVA_HOME that holds a java; a
# node image without a JDK is fine.
node_java="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
    "$CSIT_NODE_IMAGE" | sed -n 's/^JAVA_HOME=//p' | head -n 1)"

start_node() {
    local name="$1" image="$2" role="${3:-node}"
    local -a opts=(
        -d --name "$name" --hostname "$name" --network "$NET"
        --cap-add NET_ADMIN --cap-add SYS_PTRACE --shm-size 512m
    )
    # Open vSwitch on the kernel datapath and mininet need the host's
    # openvswitch module and full privileges. Opt-in only: a privileged
    # container is root on the runner, so use it on ephemeral runners.
    if [ "$role" = "tools" ] && [ "$CSIT_TOOLS_PRIVILEGED" = "true" ]; then
        opts+=(--privileged -v /lib/modules:/lib/modules:ro)
    fi
    docker run "${opts[@]}" "$image" >/dev/null
    # The node user matches the runner's $USER so harnesses can run a bare
    # `ssh $IP`.
    docker exec "$name" bash -c "
        set -e
        id -u '${node_user}' >/dev/null 2>&1 || useradd -m -s /bin/bash '${node_user}'
        echo '${node_user} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/csit
        chmod 440 /etc/sudoers.d/csit"
    # USER=root lives in /root, not /home/root: ask passwd.
    # An image may already hold the account with another primary group.
    local home group
    home=$(docker exec "$name" getent passwd "$node_user" | cut -d: -f6)
    group=$(docker exec "$name" id -gn "$node_user")
    docker exec "$name" install -d -m 700 -o "$node_user" -g "$group" "${home}/.ssh"
    if [ -n "$CSIT_NODE_PROMPT" ]; then
        # %q quotes the prompt for bash, so it is assigned literally.
        printf 'PS1=%q\n' "$CSIT_NODE_PROMPT" |
            docker exec -i "$name" sh -c 'cat >> "$1"' _ "${home}/.bashrc"
    fi
    docker cp "${key}.pub" "${name}:${home}/.ssh/authorized_keys"
    docker exec "$name" bash -c "
        chown '${node_user}:${group}' '${home}/.ssh/authorized_keys'
        chmod 600 '${home}/.ssh/authorized_keys'"
    local ip hostkey="" i
    ip=$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${NET}\").IPAddress }}" "$name")
    # The entrypoint generates host keys on start, so wait for them.
    for i in $(seq 1 30); do
        hostkey=$(docker exec "$name" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || true)
        [ -n "$hostkey" ] && break
        sleep 1
    done
    if [[ "$hostkey" != ssh-ed25519\ * ]]; then
        echo "ERROR: ${name} has no ed25519 host key" >&2
        return 1
    fi
    echo "${ip} $(cut -d' ' -f1,2 <<<"$hostkey")" >> "$known_hosts"
    echo "$ip"
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

node_ips=()
tools_ips=()
for i in $(seq 1 "$PROJECT_NODES"); do
    node_ips+=("$(start_node "csit-${CSIT_LAB_ID}-node-${i}" "$CSIT_NODE_IMAGE")")
done
for i in $(seq 1 "$TOOLS_NODES"); do
    tools_ips+=("$(start_node "csit-${CSIT_LAB_ID}-tools-${i}" "$CSIT_TOOLS_IMAGE" tools)")
done

all_ips=("${node_ips[@]}" ${tools_ips[@]+"${tools_ips[@]}"})

# builder's scripts call bare ssh/scp, so the lab's key and known_hosts go
# in ~/.ssh/config. ssh uses the first value it finds for each option, so the
# block is prepended: an existing `Host *` cannot override it. It ends with
# `Host *` so the user's own unscoped options keep applying to every host.
# lab-down removes the block.
ssh_config="${HOME}/.ssh/config"
flock "$ssh_lock"
touch "$ssh_config"
# Replaced by an atomic rename beside the resolved target: ssh readers do not
# take the lock, so they must never see a half-written file, and a symlinked
# config stays a symlink.
ssh_target="$(readlink -f "$ssh_config" && echo x)"
ssh_target="${ssh_target%$'\n'x}"
if [[ "$ssh_target" == *$'\n'* ]]; then
    echo "ERROR: ${ssh_config} resolves to a path with a line break" >&2
    exit 1
fi
tmp_config="$(mktemp "$(dirname "$ssh_target")/.csit-config.XXXXXX")"
trap 'rm -f "$tmp_config"' EXIT
{
    echo "# BEGIN csit-lab ${CSIT_LAB_ID}"
    echo "Host ${all_ips[*]}"
    echo "    User ${node_user}"
    # The bundled sshd listens on 22, whatever a user's Host * says.
    echo "    Port 22"
    echo "    IdentityFile \"${key}\""
    echo "    IdentitiesOnly yes"
    echo "    ForwardAgent no"
    echo "    UserKnownHostsFile \"${known_hosts}\""
    echo "    StrictHostKeyChecking yes"
    echo "    HostKeyAlgorithms ssh-ed25519"
    echo "    LogLevel ERROR"
    echo "    ServerAliveInterval 30"
    # A user's Host * must not proxy, multiplex or redirect lab sessions.
    echo "    ProxyJump none"
    echo "    ProxyCommand none"
    echo "    RemoteCommand none"
    echo "    RequestTTY auto"
    echo "    ControlMaster no"
    echo "    ControlPath none"
    echo "    ForwardX11 no"
    echo "    ClearAllForwardings yes"
    echo "    PermitLocalCommand no"
    echo "Host *"
    echo "# END csit-lab ${CSIT_LAB_ID}"
    cat "$ssh_target"
} > "$tmp_config"
chmod 600 "$tmp_config"
mv -f "$tmp_config" "$ssh_target"
trap - EXIT
flock -u "$ssh_lock"

for ip in "${all_ips[@]}"; do
    wait_for_ssh "$ip"
done

# Written only now that every node answers, so a lab.env means a usable lab.
java_ok=""
if [ -n "$node_java" ] &&
    docker exec "csit-${CSIT_LAB_ID}-node-1" test -x "${node_java}/bin/java"; then
    java_ok=1
fi
write_nodes() {
    local p="$1" i
    echo "NUM_${p}_SYSTEM=${PROJECT_NODES}"
    echo "${p}_SYSTEM_IP=${node_ips[0]}"
    for i in "${!node_ips[@]}"; do
        echo "${p}_SYSTEM_$((i + 1))_IP=${node_ips[$i]}"
    done
}
{
    write_nodes PROJECT
    if [ "$CSIT_ENV_PREFIX" != "PROJECT" ]; then
        write_nodes "$CSIT_ENV_PREFIX"
    fi
    echo "NUM_TOOLS_SYSTEM=${TOOLS_NODES}"
    if [ "$TOOLS_NODES" -gt 0 ]; then
        echo "TOOLS_SYSTEM_IP=${tools_ips[0]}"
        for i in "${!tools_ips[@]}"; do
            echo "TOOLS_SYSTEM_$((i + 1))_IP=${tools_ips[$i]}"
        done
    fi
    echo "CSIT_LAB_DIR=${CSIT_LAB_DIR}"
    echo "CSIT_SSH_KEY=${key}"
    echo "CSIT_NODE_USER=${node_user}"
    if [ -n "$java_ok" ]; then
        echo "CSIT_NODE_JAVA_HOME=${node_java}"
    fi
} > "$LAB_ENV"

# GITHUB_ENV keeps an earlier lab's names for the rest of the job, so any
# this lab does not set (its JDK, more nodes, another prefix) are emptied.
lab_vars="$(sed 's/=.*//' "$LAB_ENV" | tr '\n' ' ')"
read -ra old_vars <<<"${CSIT_LAB_VARS:-}"
for name in ${old_vars[@]+"${old_vars[@]}"}; do
    if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && " ${lab_vars}" != *" ${name} "* ]]; then
        echo "${name}=" >> "$LAB_ENV"
    fi
done
echo "CSIT_LAB_VARS=${lab_vars% }" >> "$LAB_ENV"

echo "---> ${LAB_ENV}"
cat "$LAB_ENV"
if [ -n "${GITHUB_ENV:-}" ]; then
    cat "$LAB_ENV" >> "$GITHUB_ENV"
    echo "CSIT_LAB_ENV=${LAB_ENV}" >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "project-system-ip=${node_ips[0]}"
        echo "lab-env-file=${LAB_ENV}"
    } >> "$GITHUB_OUTPUT"
fi
exit 0
