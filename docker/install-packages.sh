#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Install one target's project packages during the image build.
#
# Usage: csit-install-packages <target>
#
# Reads /tmp/csit-packages/<target>.txt (one Ubuntu package per line, '#'
# comments) and then runs /tmp/csit-packages/<target>.sh if present. Both
# are optional, so an image built without a packages context is the bare
# lab node. Expects a fresh `apt-get update`.
##############################################################################

set -euo pipefail

target="${1:?usage: csit-install-packages <target>}"
dir="/tmp/csit-packages"
list="${dir}/${target}.txt"
hook="${dir}/${target}.sh"

if [ -f "$list" ]; then
    pkgs=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [ -n "$line" ] || continue
        # A name starting with '-' would reach apt-get as an option.
        if [[ ! "$line" =~ ^[a-z0-9][a-z0-9+.:=~-]*$ ]]; then
            echo "ERROR: ${list}: invalid package name '${line}'" >&2
            exit 1
        fi
        pkgs+=("$line")
    done < "$list"
    if [ "${#pkgs[@]}" -gt 0 ]; then
        echo "---> ${target}: installing ${#pkgs[*]} package(s) from ${target}.txt"
        apt-get install -y --no-install-recommends "${pkgs[@]}"
    fi
fi

if [ -f "$hook" ]; then
    echo "---> ${target}: running ${target}.sh"
    bash "$hook"
fi

# Give an installed JDK a fixed home, whatever its version or architecture.
if java_bin="$(command -v java)"; then
    java_bin="$(readlink -f "$java_bin")"
    java_home="${java_bin%/bin/java}"
    ln -sfn "${java_home%/jre}" /usr/lib/jvm/csit-java
fi
