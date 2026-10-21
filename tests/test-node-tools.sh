#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check that a CSIT node image carries every binary a project's suites shell
# out to over SSH.
#
# A missing one does not look like a missing tool: the suite setup dies, the
# suite scores 0 and the job just looks broken. So the project lists the
# binaries once and the built image is checked against the list.
#
# Usage: tests/test-node-tools.sh [image] [binaries-file]
#   image          default: csit-tools:test
#   binaries-file  one binary per line, '#' comments
#                  default: examples/odl/required-binaries.txt
#
# sshd and sudo are always required: the lab itself needs them. A listed
# `java` must also be what JAVA_HOME points at, and a listed `virtualenv`
# must build a venv with a working pip.
##############################################################################

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:-csit-tools:test}"
list="${2:-${repo}/examples/odl/required-binaries.txt}"

if ! docker image inspect "${image}" >/dev/null 2>&1; then
    # CI builds the image first, so a missing one there is a failure.
    if [ -n "${CI:-}" ]; then
        echo "FAIL: image ${image} not present" >&2
        exit 1
    fi
    echo "SKIP: image ${image} not present; build it with"
    echo "  docker build --build-context packages=examples/odl/packages \\"
    echo "    --target tools -t ${image} -f docker/Dockerfile.node docker"
    exit 0
fi

required=(sshd sudo)
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -n "$line" ] && required+=("$line")
done < "$list"

has() {
    local b
    for b in "${required[@]}"; do
        [ "$b" = "$1" ] && return 0
    done
    return 1
}

missing="$(docker run --rm --entrypoint bash "${image}" -c '
    export PATH="$PATH:/usr/sbin:/sbin"
    for b in "$@"; do
        command -v "${b}" >/dev/null 2>&1 || echo "${b}"
    done' _ "${required[@]}")"

if [ -n "${missing}" ]; then
    echo "FAIL: ${image} is missing:" >&2
    # shellcheck disable=SC2086  # deliberate split: one binary name per line
    printf '  %s\n' ${missing} >&2
    exit 1
fi

# lab-up hands the image's JAVA_HOME to the test command, and suites run
# ${JAVA_HOME}/bin/java and jstack on the node.
if has java; then
    docker run --rm --entrypoint bash "${image}" -c '
        set -e
        test -n "${JAVA_HOME:-}"
        "${JAVA_HOME}/bin/java" -version
        test -x "${JAVA_HOME}/bin/jstack"' >/dev/null 2>&1 || {
        echo "FAIL: ${image} JAVA_HOME does not point at a JDK with jstack" >&2
        exit 1
    }
fi

# Suites that create a virtualenv run `pip install` in it straight away.
if has virtualenv; then
    docker run --rm --entrypoint bash "${image}" -c '
        set -e
        cd /tmp
        virtualenv v >/dev/null
        ./v/bin/pip --version >/dev/null' \
        || { echo "FAIL: virtualenv cannot build a pip-capable venv" >&2; exit 1; }
fi

echo "PASS: ${image} carries all ${#required[@]} required binaries"
