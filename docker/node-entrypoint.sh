#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Entrypoint for a CSIT lab node.
#
# The image ships without SSH host keys, so every container gets its own;
# lab-up reads the public key back into a per-lab known_hosts file.
# Containers have no systemd, so when the project's packages include Open
# vSwitch its two daemons start here too.
##############################################################################

set -euo pipefail

if command -v ovsdb-server >/dev/null 2>&1; then
    mkdir -p /var/run/openvswitch /var/log/openvswitch /etc/openvswitch
    if [ ! -f /etc/openvswitch/conf.db ]; then
        ovsdb-tool create /etc/openvswitch/conf.db \
            /usr/share/openvswitch/vswitch.ovsschema
    fi
    ovsdb-server /etc/openvswitch/conf.db \
        --remote=punix:/var/run/openvswitch/db.sock \
        --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
        --pidfile --detach --log-file
    ovs-vsctl --no-wait init
    ovs-vswitchd --pidfile --detach --log-file
fi

ssh-keygen -A
exec /usr/sbin/sshd -D -e
