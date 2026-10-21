#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check that a robot-output path stays inside the workspace (the current
# directory), physically as well as by name, then remove that run's results
# so a failed run cannot leave an earlier run's passing ones behind.
#
# A symlinked parent directory would point the removal, and the gate's
# robot-gate.json, outside the workspace. The removal acts on the leaf
# names, so a symlinked output.xml goes rather than its target; the
# --check-only pass before the gate refuses one planted since.
#
# Usage: clear-results.sh [--check-only] <robot-output>
##############################################################################

set -euo pipefail

check_only=""
if [ "${1:-}" = "--check-only" ]; then
    check_only=1
    shift
fi
out="${1:?usage: clear-results.sh [--check-only] <robot-output>}"

# dirname drops trailing newlines, so a line break would check one
# directory and remove from another.
case "/${out}/" in
    *$'\n'*|*$'\r'*)
        echo "ERROR: robot-output must not contain a line break" >&2
        exit 1 ;;
    //*|*/../*)
        echo "ERROR: robot-output must be a path inside the workspace" >&2
        exit 1 ;;
esac
out_dir="$(dirname "$out")"
# Check the deepest directory that exists, so missing components below an
# external link cannot skip this; with no `..`, they are created under it.
existing="$out_dir"
while [ ! -d "$existing" ]; do
    if [ -L "$existing" ]; then
        echo "ERROR: robot-output directory ${out_dir} passes through" \
            "dangling symlink ${existing}" >&2
        exit 1
    fi
    existing="$(dirname "$existing")"
done
# The trailing x keeps a newline that ends a link target, which command
# substitution would otherwise strip to name the workspace itself.
workspace="$(pwd -P && echo x)"
workspace="${workspace%$'\n'x}"
real_dir="$(cd "$existing" && pwd -P && echo x)"
real_dir="${real_dir%$'\n'x}"
case "${real_dir}/" in
    "${workspace}/"*) ;;
    *)
        echo "ERROR: robot-output directory ${out_dir} resolves to" \
            "${real_dir}, outside the workspace" >&2
        exit 1 ;;
esac

if [ -z "$check_only" ]; then
    rm -f -- "$out" "${out_dir}/log.html" "${out_dir}/report.html" \
        "${out_dir}/robot-gate.json"
elif [ -L "$out" ]; then
    # The test command could link output.xml to an older passing result;
    # the gate judges this run's own file or nothing.
    echo "ERROR: robot-output ${out} is a symlink, not this run's result" >&2
    exit 1
fi
