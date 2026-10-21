#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Build cbench for the OpenDaylight tools node.
#
# cbench has no distro package, so it is built the way builder's
# packer/provision/mininet-ovs-217.yaml builds it: same fork, same
# Makefile.am LDADD fix, same install path (010_Cbench.robot asserts
# /usr/local/bin/cbench). Upstream is dormant (HEAD is from 2017), so the
# commit is pinned. build_mtcbench.sh also builds an oflops binary that
# fails to link, so its result cannot be trusted; only liboflops_test,
# which cbench links, is built here, and any failure fails the image.
# The build tooling is removed again afterwards.
##############################################################################

set -euo pipefail

MTCBENCH_REF="dd2409235a35ede75ad91c8512cd7a9af5fa9f1a"
build_deps=(
    autoconf automake build-essential ca-certificates git libconfig-dev
    libffi-dev libpcap-dev libsnmp-dev libssl-dev libtool make pkg-config
)

mapfile -t manual < <(apt-mark showmanual)
apt-get install -y --no-install-recommends "${build_deps[@]}"

# Fetch only the pinned commit: no branch is consulted, so upstream
# changes cannot alter what gets built, and the full SHA fixes the content.
src="$(mktemp -d)"
git init --quiet "${src}"
git -C "${src}" fetch --quiet --depth 1 \
    https://github.com/intracom-telecom-sdn/mtcbench.git "${MTCBENCH_REF}"
git -C "${src}" checkout --quiet FETCH_HEAD
sed -i 's|^LDADD=-ldl -lpcap -lnetsnmp -loflops_test$|LDADD=-ldl -lpcap -lnetsnmp liboflops_test.la|' \
    "${src}/oflops/Makefile.am"
(
    cd "${src}/oflops"
    ./boot.sh
    ./configure --with-openflow-src-dir=../openflow/
    make liboflops_test.la
    make -C cbench LIBS="-L${src}/oflops/.libs"
    install -m 755 cbench/cbench /usr/local/bin/cbench
)
rm -rf "${src}"

# Drop the build tooling but keep anything the node already had.
apt-mark auto "${build_deps[@]}" >/dev/null
apt-mark manual "${manual[@]}" >/dev/null
apt-get purge -y --auto-remove

if ldd /usr/local/bin/cbench | grep -q "not found"; then
    echo "ERROR: cbench lost a runtime library with the build tooling" >&2
    ldd /usr/local/bin/cbench >&2
    exit 1
fi
