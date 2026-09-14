#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Resolve the ODL karaf distribution to test.
#
# Port of releng/builder jjb/integration/integration-set-variables.sh and
# integration-detect-variables.sh, minus the Jenkins `inject` plumbing.
#
# Inputs  (env): KARAF_VERSION JDKVERSION BUNDLE_URL DISTROBRANCH
#                ODLNEXUSPROXY ODL_NEXUS_REPO
# Outputs (env): JAVA_HOME KARAF_ARTIFACT KARAF_PROJECT ACTUAL_BUNDLE_URL
#                BUNDLE BUNDLE_VERSION BUNDLEFOLDER NEXUSURL_PREFIX
##############################################################################

set -euo pipefail

KARAF_VERSION="${KARAF_VERSION:-karaf4}"
JDKVERSION="${JDKVERSION:-openjdk21}"
BUNDLE_URL="${BUNDLE_URL:-last}"
DISTROBRANCH="${DISTROBRANCH:-master}"
NEXUSURL_PREFIX="${ODLNEXUSPROXY:-https://nexus.opendaylight.org}"
ODL_NEXUS_REPO="${ODL_NEXUS_REPO:-content/repositories/opendaylight.snapshot}"

case "$KARAF_VERSION" in
    odl)        KARAF_ARTIFACT="opendaylight";          KARAF_PROJECT="integration" ;;
    karaf3)     KARAF_ARTIFACT="distribution-karaf";    KARAF_PROJECT="integration" ;;
    controller) KARAF_ARTIFACT="controller-test-karaf"; KARAF_PROJECT="controller" ;;
    netconf)    KARAF_ARTIFACT="netconf-karaf";         KARAF_PROJECT="netconf" ;;
    bgpcep)     KARAF_ARTIFACT="bgpcep-karaf";          KARAF_PROJECT="bgpcep" ;;
    *)          KARAF_ARTIFACT="karaf";                 KARAF_PROJECT="integration" ;;
esac

case "$JDKVERSION" in
    openjdk21) JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64" ;;
    openjdk17) JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64" ;;
    openjdk11) JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64" ;;
    openjdk8)  JAVA_HOME="/usr/lib/jvm/java-1.8.0-openjdk-amd64" ;;
    *)         JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64" ;;
esac

# ponytail: the old `xpath` perl one-liner is replaced by python3 + stdlib
# ElementTree. python3 is present on GitHub runners, ODL build VMs and the node
# image, whereas xmllint/perl-XML-XPath are not. Only two queries are needed,
# so they are named rather than a generic XPath evaluator.
xml_text() {
    python3 - "$1" "$2" <<'PY'
import sys, xml.etree.ElementTree as ET

path, mode = sys.argv[1], sys.argv[2]
root = ET.parse(path).getroot()
tag = lambda e: e.tag.rsplit('}', 1)[-1]

if mode == "project-version":
    # The distribution version is the first /project/version, never a
    # dependency's or the parent's, so only direct children are considered.
    out = next((e.text for e in root if tag(e) == "version"), "")
elif mode == "snapshot-zip":
    out = ""
    for sv in root.iter():
        if tag(sv) != "snapshotVersion":
            continue
        kids = {tag(k): (k.text or "") for k in sv}
        if kids.get("extension") == "zip":
            out = kids.get("value", "")
            break
else:
    sys.exit("unknown mode: " + mode)

print((out or "").strip(), end="")
PY
}

if [ "$BUNDLE_URL" = "last" ]; then
    case "$KARAF_ARTIFACT" in
        opendaylight)
            pom="https://raw.githubusercontent.com/opendaylight/integration-distribution/${DISTROBRANCH}/opendaylight/pom.xml" ;;
        netconf-karaf)
            pom="https://raw.githubusercontent.com/opendaylight/netconf/${DISTROBRANCH}/usecase/karaf/pom.xml" ;;
        controller-test-karaf)
            pom="https://raw.githubusercontent.com/opendaylight/${KARAF_PROJECT}/${DISTROBRANCH}/karaf/pom.xml" ;;
        bgpcep-karaf)
            pom="https://raw.githubusercontent.com/opendaylight/${KARAF_PROJECT}/${DISTROBRANCH}/distribution-karaf/pom.xml" ;;
        *)
            pom="https://raw.githubusercontent.com/opendaylight/integration-distribution/${DISTROBRANCH}/pom.xml" ;;
    esac

    echo "Fetching pom: $pom"
    curl -sSfL -o pom.xml "$pom"

    # The distribution version is the first /project/version, not a dependency's.
    BUNDLE_VERSION=$(xml_text pom.xml project-version)
    [ -n "$BUNDLE_VERSION" ] || { echo "ERROR: could not read version from $pom" >&2; exit 1; }
    echo "Bundle version is ${BUNDLE_VERSION}"

    NEXUSPATH="${NEXUSURL_PREFIX}/${ODL_NEXUS_REPO}/org/opendaylight/${KARAF_PROJECT}/${KARAF_ARTIFACT}"
    curl -sSfL -o maven-metadata.xml "${NEXUSPATH}/${BUNDLE_VERSION}/maven-metadata.xml"

    TIMESTAMP=$(xml_text maven-metadata.xml snapshot-zip)
    [ -n "$TIMESTAMP" ] || { echo "ERROR: no zip snapshotVersion in maven-metadata.xml" >&2; exit 1; }
    echo "Nexus timestamp is ${TIMESTAMP}"

    BUNDLEFOLDER="${KARAF_ARTIFACT}-${BUNDLE_VERSION}"
    BUNDLE="${KARAF_ARTIFACT}-${TIMESTAMP}.zip"
    ACTUAL_BUNDLE_URL="${NEXUSPATH}/${BUNDLE_VERSION}/${BUNDLE}"
else
    ACTUAL_BUNDLE_URL="${BUNDLE_URL}"
    BUNDLE="${BUNDLE_URL##*/}"
    ARTIFACT="$(basename "$(dirname "$(dirname "${BUNDLE_URL}")")")"
    BUNDLE_VERSION="$(basename "$(dirname "${BUNDLE_URL}")")"
    BUNDLEFOLDER="${ARTIFACT}-${BUNDLE_VERSION}"
fi

echo "Distribution bundle URL is ${ACTUAL_BUNDLE_URL}"
echo "Distribution folder is ${BUNDLEFOLDER}"

# GITHUB_ENV when running under Actions, a plain file otherwise (local testing).
out="${GITHUB_ENV:-${CSIT_ENV_FILE:-/dev/stdout}}"
{
    echo "JAVA_HOME=${JAVA_HOME}"
    echo "KARAF_ARTIFACT=${KARAF_ARTIFACT}"
    echo "KARAF_PROJECT=${KARAF_PROJECT}"
    echo "ACTUAL_BUNDLE_URL=${ACTUAL_BUNDLE_URL}"
    echo "BUNDLE=${BUNDLE}"
    echo "BUNDLE_VERSION=${BUNDLE_VERSION}"
    echo "BUNDLEFOLDER=${BUNDLEFOLDER}"
    echo "NEXUSURL_PREFIX=${NEXUSURL_PREFIX}"
} >> "$out"
