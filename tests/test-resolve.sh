#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Check scripts/resolve-artifact.sh against a fake Maven repository served
# from a local http.server: a release, a snapshot with a timestamped zip next
# to a classified one, and a pom to read the version from.
#
# Usage: tests/test-resolve.sh
##############################################################################

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve="${here}/../scripts/resolve-artifact.sh"
tmp="$(mktemp -d)"
server=""
trap 'if [ -n "$server" ]; then kill "$server" 2>/dev/null; fi; rm -rf "$tmp"' EXIT
unset GITHUB_ENV CSIT_ENV_FILE

repo="${tmp}/repo"
art="${repo}/org/example/proj/proj-dist"
mkdir -p "${art}/1.2.3" "${art}/2.0.0-SNAPSHOT" "${art}/3.0.0-SNAPSHOT"
# A hostile repository must not smuggle an extra GITHUB_ENV line in.
printf '%s\n' '<metadata><versioning><snapshotVersions><snapshotVersion>' \
    '<extension>zip</extension><value>3.0.0-1' 'INJECTED=1</value>' \
    '</snapshotVersion></snapshotVersions></versioning></metadata>' \
    >"${art}/3.0.0-SNAPSHOT/maven-metadata.xml"
cat >"${art}/2.0.0-SNAPSHOT/maven-metadata.xml" <<'XML'
<metadata><versioning><snapshotVersions>
  <snapshotVersion><classifier>sources</classifier><extension>zip</extension>
    <value>2.0.0-20260101.000000-9</value></snapshotVersion>
  <snapshotVersion><extension>pom</extension>
    <value>2.0.0-20260102.000000-7</value></snapshotVersion>
  <snapshotVersion><extension>zip</extension>
    <value>2.0.0-20260102.000000-7</value></snapshotVersion>
</snapshotVersions></versioning></metadata>
XML
cat >"${repo}/pom.xml" <<'XML'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <parent><version>9.9.9</version></parent>
  <version>2.0.0-SNAPSHOT</version>
  <dependencies><dependency><version>1.0</version></dependency></dependencies>
</project>
XML

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server --bind 127.0.0.1 --directory "$repo" "$port" >/dev/null 2>&1 &
server=$!
url="http://127.0.0.1:${port}"
for _ in $(seq 1 50); do
    curl -sf -o /dev/null "${url}/pom.xml" && break
    sleep 0.1
done

fail=0
# $1 name, $2 expected exit (0/1), $3 expected output substring, then env
check() {
    local name="$1" want_rc="$2" want="$3" out rc=0
    shift 3
    out="$(env -i PATH="$PATH" HOME="$HOME" "$@" bash "$resolve" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then rc=1; fi
    if [ "$rc" -ne "$want_rc" ] || [[ "$out" != *"$want"* ]]; then
        echo "FAIL: ${name} (exit ${rc}, want ${want_rc} with '${want}')" >&2
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        fail=1
    else
        echo "ok: ${name}"
    fi
}
coords=(CSIT_MAVEN_REPO_URL="$url" CSIT_GROUP_ID=org.example.proj CSIT_ARTIFACT_ID=proj-dist)

check "release by coordinates" 0 \
    "ARTIFACT_URL=${url}/org/example/proj/proj-dist/1.2.3/proj-dist-1.2.3.zip" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=1.2.3
check "snapshot value with a line break is refused" 1 "snapshotVersion" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=3.0.0-SNAPSHOT
check "release folder" 0 "ARTIFACT_FOLDER=proj-dist-1.2.3" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=1.2.3
check "snapshot skips classified and pom entries" 0 \
    "ARTIFACT_FILE=proj-dist-2.0.0-20260102.000000-7.zip" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=2.0.0-SNAPSHOT
check "version read from pom, not parent or dependency" 0 \
    "ARTIFACT_VERSION=2.0.0-SNAPSHOT" \
    "${coords[@]}" CSIT_VERSION_POM_URL="${url}/pom.xml"
check "explicit artifact url" 0 "ARTIFACT_FOLDER=karaf-0.21.0" \
    CSIT_ARTIFACT_URL=https://repo.example/org/x/karaf/0.21.0/karaf-0.21.0.zip
check "other extension" 0 "ARTIFACT_FILE=proj-dist-1.2.3.tar.gz" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=1.2.3 CSIT_ARTIFACT_EXTENSION=tar.gz
check "plain http warns" 0 "::warning::maven-repo-url is plain http" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=1.2.3

check "nothing given" 1 "need artifact-url" CSIT_ARTIFACT_EXTENSION=zip
check "url and coordinates" 1 "not both" \
    CSIT_ARTIFACT_URL=https://repo.example/a/b/c.zip "${coords[@]}"
check "version and pom" 1 "not both" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=1 CSIT_VERSION_POM_URL="${url}/pom.xml"
check "no version source" 1 "need artifact-version" "${coords[@]}"
check "non-http url" 1 "must be an http(s) URL" \
    CSIT_ARTIFACT_URL=file:///etc/passwd
check "newline in url" 1 "must be an http(s) URL" \
    CSIT_ARTIFACT_URL=$'https://repo.example/a/1/a.zip\nEVIL=1'
check "query in url" 1 "query or fragment" \
    'CSIT_ARTIFACT_URL=https://repo.example/karaf/1.2.3/karaf-1.2.3.zip?token=a/b'
check "fragment in url" 1 "query or fragment" \
    'CSIT_ARTIFACT_URL=https://repo.example/karaf/1.2.3/karaf-1.2.3.zip#x/y'
check "url without the layout" 1 "<artifactId>/<version>/<file>" \
    CSIT_ARTIFACT_URL=https://repo.example/karaf.zip
check "encoded version in url" 1 "artifact-version" \
    'CSIT_ARTIFACT_URL=https://repo.example/k/1.0%2F..%2Fx/karaf.zip'
check "bad group-id" 1 "group-id" \
    CSIT_MAVEN_REPO_URL="$url" CSIT_GROUP_ID='org/../x' \
    CSIT_ARTIFACT_ID=proj-dist CSIT_ARTIFACT_VERSION=1
check "bad version" 1 "artifact-version" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION='1/../../x'
check "bad extension" 1 "artifact-extension" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=1 CSIT_ARTIFACT_EXTENSION='zip/x'
check "missing snapshot metadata" 1 "404" \
    "${coords[@]}" CSIT_ARTIFACT_VERSION=4.0.0-SNAPSHOT

# Outputs go to both GITHUB_ENV and CSIT_ENV_FILE when set.
: >"${tmp}/ghenv"; : >"${tmp}/envfile"
env -i PATH="$PATH" HOME="$HOME" GITHUB_ENV="${tmp}/ghenv" \
    CSIT_ENV_FILE="${tmp}/envfile" "${coords[@]}" CSIT_ARTIFACT_VERSION=1.2.3 \
    bash "$resolve" >/dev/null
if grep -qx "ARTIFACT_VERSION=1.2.3" "${tmp}/ghenv" &&
    cmp -s "${tmp}/ghenv" "${tmp}/envfile" && [ "$(wc -l <"${tmp}/ghenv")" -eq 4 ]; then
    echo "ok: written to GITHUB_ENV and CSIT_ENV_FILE"
else
    echo "FAIL: env file outputs" >&2
    fail=1
fi

exit "$fail"
