#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Entrypoint for the CSIT tools node.
#
# On the OpenStack mininet-ovs-217 image, systemd starts openvswitch-switch.
# Containers have no systemd, so start the two OVS daemons here and then hand
# over to sshd, which is what the rest of CSIT talks to.
##############################################################################

set -euo pipefail

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

ovs-vsctl show

exec /usr/sbin/sshd -D -e
