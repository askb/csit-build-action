#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Resolve the build artifact a CSIT run tests, from a Maven repository.
#
# Either name the artifact outright:
#   CSIT_ARTIFACT_URL        .../<artifactId>/<version>/<file>
# or give its Maven coordinates:
#   CSIT_MAVEN_REPO_URL      repository root, e.g. https://repo.example/maven
#   CSIT_GROUP_ID            org.example.project
#   CSIT_ARTIFACT_ID         project-dist
#   CSIT_ARTIFACT_VERSION    1.2.3 or 1.3.0-SNAPSHOT; or, instead,
#   CSIT_VERSION_POM_URL     a pom.xml whose /project/version is the version
#   CSIT_ARTIFACT_EXTENSION  default: zip
# A -SNAPSHOT version resolves to the newest timestamped file listed in that
# version's maven-metadata.xml.
#
# Outputs: ARTIFACT_URL ARTIFACT_FILE ARTIFACT_VERSION ARTIFACT_FOLDER
# (folder is <artifactId>-<version>, the directory such archives unpack to)
# go to GITHUB_ENV and CSIT_ENV_FILE when set, otherwise to stdout.
##############################################################################

set -euo pipefail

artifact_url="${CSIT_ARTIFACT_URL:-}"
repo_url="${CSIT_MAVEN_REPO_URL:-}"
group_id="${CSIT_GROUP_ID:-}"
artifact_id="${CSIT_ARTIFACT_ID:-}"
version="${CSIT_ARTIFACT_VERSION:-}"
pom_url="${CSIT_VERSION_POM_URL:-}"
ext="${CSIT_ARTIFACT_EXTENSION:-zip}"

die() { echo "ERROR: $*" >&2; exit 1; }

check_url() {
    local name="$1" url="$2"
    [[ "$url" =~ ^https?://[^[:space:]]+$ ]] \
        || die "${name} must be an http(s) URL without whitespace"
    if [[ "$url" == http://* ]]; then
        echo "::warning::${name} is plain http; the artifact is not verified in transit"
    fi
}
check_re() {
    local name="$1" value="$2" re="$3"
    [[ "$value" =~ $re ]] || die "${name} '${value}' must match ${re}"
}

# Only two queries are needed, so they are named rather than a generic XPath
# evaluator; python3 is on every runner, xmllint is not.
xml_text() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, xml.etree.ElementTree as ET

path, mode, ext = sys.argv[1:4]
root = ET.parse(path).getroot()
tag = lambda e: e.tag.rsplit('}', 1)[-1]

out = ""
if mode == "project-version":
    # The first direct /project/version, never a dependency's or the parent's.
    out = next((e.text for e in root if tag(e) == "version"), "")
elif mode == "snapshot-value":
    for sv in root.iter():
        if tag(sv) != "snapshotVersion":
            continue
        kids = {tag(k): (k.text or "") for k in sv}
        if kids.get("extension") == ext and not kids.get("classifier"):
            out = kids.get("value", "")
            break
else:
    sys.exit("unknown mode: " + mode)
print((out or "").strip(), end="")
PY
}

check_re artifact-extension "$ext" '^[A-Za-z0-9][A-Za-z0-9.]*$'

if [ -n "$artifact_url" ]; then
    if [ -n "${repo_url}${group_id}${artifact_id}${version}${pom_url}" ]; then
        die "give artifact-url or Maven coordinates, not both"
    fi
    check_url artifact-url "$artifact_url"
    # The file, version and folder come from the path; a query or fragment
    # would be read as part of it and give the test command wrong metadata.
    [[ "$artifact_url" != *[?#]* ]] \
        || die "artifact-url must not have a query or fragment"
    [[ "$artifact_url" =~ ^https?://[^/]+/([^/]+/)*[^/]+/[^/]+/[^/]+$ ]] \
        || die "artifact-url must end in <artifactId>/<version>/<file>"
    file="${artifact_url##*/}"
    version="$(basename "$(dirname "$artifact_url")")"
    artifact_id="$(basename "$(dirname "$(dirname "$artifact_url")")")"
    check_re artifact-id "$artifact_id" '^[A-Za-z0-9_.-]+$'
    check_re artifact-version "$version" '^[A-Za-z0-9][A-Za-z0-9_.+-]*$'
    url="$artifact_url"
else
    [ -n "$repo_url" ] && [ -n "$group_id" ] && [ -n "$artifact_id" ] \
        || die "need artifact-url, or maven-repo-url + group-id + artifact-id"
    check_url maven-repo-url "$repo_url"
    check_re group-id "$group_id" '^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$'
    check_re artifact-id "$artifact_id" '^[A-Za-z0-9_.-]+$'
    if [ -n "$version" ] && [ -n "$pom_url" ]; then
        die "give artifact-version or version-pom-url, not both"
    fi

    # Downloads go to a private directory, never the caller's working tree.
    dl_dir="$(mktemp -d)"
    trap 'rm -rf "$dl_dir"' EXIT

    if [ -z "$version" ]; then
        [ -n "$pom_url" ] || die "need artifact-version or version-pom-url"
        check_url version-pom-url "$pom_url"
        echo "Fetching ${pom_url}"
        curl -sSfL -o "${dl_dir}/pom.xml" "$pom_url"
        version="$(xml_text "${dl_dir}/pom.xml" project-version "")"
        [ -n "$version" ] || die "no /project/version in ${pom_url}"
    fi
    check_re artifact-version "$version" '^[A-Za-z0-9][A-Za-z0-9_.+-]*$'

    base="${repo_url%/}/${group_id//.//}/${artifact_id}/${version}"
    if [[ "$version" == *-SNAPSHOT ]]; then
        curl -sSfL -o "${dl_dir}/maven-metadata.xml" "${base}/maven-metadata.xml"
        stamp="$(xml_text "${dl_dir}/maven-metadata.xml" snapshot-value "$ext")"
        [ -n "$stamp" ] || die "no ${ext} snapshotVersion in ${base}/maven-metadata.xml"
        # Downloaded data ends up in GITHUB_ENV, so it gets the version rules.
        check_re snapshotVersion "$stamp" '^[A-Za-z0-9][A-Za-z0-9_.+-]*$'
        file="${artifact_id}-${stamp}.${ext}"
    else
        file="${artifact_id}-${version}.${ext}"
    fi
    url="${base}/${file}"
fi

folder="${artifact_id}-${version}"
echo "Artifact URL is ${url}"
echo "Artifact folder is ${folder}"

lines=(
    "ARTIFACT_URL=${url}"
    "ARTIFACT_FILE=${file}"
    "ARTIFACT_VERSION=${version}"
    "ARTIFACT_FOLDER=${folder}"
)
targets=()
[ -n "${GITHUB_ENV:-}" ] && targets+=("$GITHUB_ENV")
[ -n "${CSIT_ENV_FILE:-}" ] && targets+=("$CSIT_ENV_FILE")
if [ "${#targets[@]}" -gt 0 ]; then
    printf '%s\n' "${lines[@]}" | tee -a "${targets[@]}" >/dev/null
else
    printf '%s\n' "${lines[@]}"
fi
