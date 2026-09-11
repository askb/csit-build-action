<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🧪 CSIT Build Action

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/askb/csit-build-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/askb/csit-build-action/badge)](https://scorecard.dev/viewer/?uri=github.com/askb/csit-build-action)
<!-- prettier-ignore-end -->

Run OpenDaylight-style CSIT (Continuous System Integration Test) jobs on GitHub
Actions, replacing the `inttest-csit-1node` / `inttest-csit-3node` Jenkins Job
Builder templates in `releng/builder`.

## Design

The CSIT logic is **not** reimplemented. `releng/builder`'s own scripts stay the
single source of truth and are executed unmodified:

<!-- markdownlint-disable MD013 -->

| releng/builder script | role |
| --- | --- |
| `jjb/integration/common-functions.sh` | karaf deploy/configure/collect helpers |
| `jjb/integration/integration-install-robotframework.sh` | robot venv + requirements |
| `jjb/integration/integration-deploy-controller-run-test.sh` | 1-node deploy + robot |
| `jjb/integration/integration-start-cluster-run-test.sh` | 3-node deploy + robot |
| `global-jjb/jenkins-init-scripts/lf-env.sh` | `lf-activate-venv` |

<!-- markdownlint-enable MD013 -->

Only the pieces that were bound to Jenkins or OpenStack are replaced:

<!-- markdownlint-disable MD013 -->

| Jenkins / JJB | replacement |
| --- | --- |
| `lf-stack-create` (Heat) | `scripts/lab-up-<backend>.sh` |
| `integration-get-slave-addresses.sh` | same, emits identical `slave_addresses.txt` |
| `copy-common-functions.sh` (`openstack stack show`) | node list from the lab step |
| `integration-set-variables.sh` + `integration-detect-variables.sh` | `scripts/resolve-distribution.sh` |
| `inject` build steps | `GITHUB_ENV` / sourced env files |
| `lf-stack-delete` | `scripts/lab-down-<backend>.sh` |
| robot publisher, `lf-infra-publish` | `actions/upload-artifact` |
| Robot plugin verdict + email | `scripts/robot-gate.py` (see Reporting) |

<!-- markdownlint-enable MD013 -->

The contract the robot suites depend on is unchanged: a set of SSH-reachable
hosts exposed as `ODL_SYSTEM_n_IP` / `TOOLS_SYSTEM_n_IP`.

## Backends

<!-- markdownlint-disable MD013 -->

| backend | nodes are | use for |
| --- | --- | --- |
| `docker` | containers on the GitHub runner | jobs that need no mininet or OVS |
| `openstack` | Heat stack reached over Tailscale | jobs needing real mininet/OVS |

<!-- markdownlint-enable MD013 -->

## Usage

```yaml
- uses: actions/checkout@v5            # releng/builder, submodules: true
  with:
    submodules: true
- uses: actions/checkout@v5            # integration/test
  with:
    repository: opendaylight/integration-test
    ref: stable/vanadium
    path: test
- uses: lfreleng-actions/csit-build-action@v1
  with:
    distribution-branch: stable/vanadium
    distribution-stream: vanadium
    install-features: "odl-daexim-all,odl-netconf-topology,odl-jolokia"
    test-plan: daexim-basic.txt
    stream-test-plan: daexim-basic-vanadium.txt
```

## Reporting

Jenkins gave each CSIT job a Robot-plugin verdict and mailed the project.
Whether an ODL release ships is a community decision, so the same information
has to be readable on the run itself. `scripts/robot-gate.py` covers both
halves and is the only parser:

<!-- markdownlint-disable MD013 -->

| level | who renders it | what it shows |
| --- | --- | --- |
| per job | `mode: run`, at the end of every job | that job's verdict, one row per robot suite, the failing tests, and every test name with its status |
| per fan-out | `mode: report` | one go/no-go table across every job that was dispatched |

<!-- markdownlint-enable MD013 -->

Both write markdown to `$GITHUB_STEP_SUMMARY`, so the report is on the run page
and needs no artifact download. `mode: report` also writes `csit-summary.md` so
the table can be pasted into a release discussion.

The per-job report applies the Jenkins `robot-pass-threshold` /
`robot-unstable-threshold` values; builder's run scripts end robot with
`|| true`, so without this a run in which every test failed would still report
success. Skipped tests are counted and shown but deliberately stay out of the
pass rate, which keeps the verdict identical to the Jenkins one.

A job listed in `expected-jobs` that produced no `output.xml` is reported as an
error row, never dropped: a silently missing job is the one defect that would
make the whole report untrustworthy. `expected-jobs` accepts the JSON array the
matrix was fed, or a plain newline-separated list of names.

### Published report

Set `html-dir` on `mode: report` and the action also writes a
self-contained site there, for `actions/upload-pages-artifact`:

```text
site/index.html          landing page: verdict, one row per dispatched job
site/report.json         the same data, machine-readable
site/csit-summary.md     the step-summary markdown
site/<job>/report.html   that job's own Robot report
site/<job>/log.html      that job's own Robot log
```

A step summary disappears behind a login and an artifact expires; a release
discussion needs a URL that outlives both.

The per-job drill-down is Robot's own `report.html`, copied in rather than
regenerated — the same page ODL reads on Jenkins today. `rebot` could
merge every job into one tree instead, but it names each merged suite from the
robot suite name and those collide across jobs (two suites both called
`Openflowplugin`, no way to tell which job failed), which is useless as a
release gate.

## Inputs

Every input maps to a JJB CSIT job parameter, so a JJB job definition
translates field for field.

<!-- markdownlint-disable MD013 -->

<!-- markdownlint-disable MD013 -->

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| mode | False | `run` | lab-up \| run \| lab-down \| resolve \| report |
| backend | False | `docker` | Node provider: 'docker' (runner-local containers) or 'openstack' (Heat + Tailscale) |
| odl-nodes | False | `1` | Number of controller nodes (VM_0_COUNT in JJB) |
| tools-nodes | False | `0` | Number of tools/mininet nodes (VM_1_COUNT in JJB) |
| node-image | False | `ghcr.io/askb/csit-node:22.04-jdk21` | Container image used for controller nodes (docker backend) |
| tools-image | False | `ghcr.io/askb/csit-tools:22.04-ovs217` | Container image used for tools nodes (docker backend); stands in for the mininet-ovs-217 VM image |
| csit-scripts-dir | False | `jjb/integration` | Path to a checked-out releng/builder jjb/integration directory. These scripts stay the single source of truth for CSIT behaviour. |
| lf-env | False | - | Path to global-jjb jenkins-init-scripts/lf-env.sh |
| test-dir | False | `test` | Path to a checked-out integration/test repository |
| bundle-url | False | `last` | Karaf distribution zip URL, or 'last' to resolve the newest snapshot |
| karaf-version | False | `karaf4` | karaf4 \| netconf \| bgpcep \| controller \| odl \| karaf3 |
| jdk-version | False | `openjdk21` | openjdk21 \| openjdk17 \| openjdk11 \| openjdk8 |
| distribution-branch | False | `master` | Branch of integration/distribution the bundle is built from (DISTROBRANCH) |
| distribution-stream | True | - | Stream name suites branch on (DISTROSTREAM), e.g. chromium |
| install-features | False | - | Comma separated karaf features to install (CONTROLLERFEATURES) |
| controller-scope | False | `only` | 'only' or 'all' (CONTROLLERSCOPE) |
| controller-max-mem | False | `2048m` | Karaf max heap (CONTROLLERMAXMEM) |
| debug-map | False | - | Space separated module:LEVEL debug map (CONTROLLERDEBUGMAP) |
| use-features-boot | False | `True` | Append features to featuresBoot instead of installing at runtime |
| elasticsearch-attribute | False | `disabled` | JVM metric harvesting period, or 'disabled' |
| karaf-based-controller | False | `True` | 'True' when the project ships a karaf distribution (IS_KARAF_APPL) |
| test-plan | True | - | Fallback robot test plan filename (TESTPLAN) |
| stream-test-plan | False | - | Stream specific robot test plan filename (STREAMTESTPLAN) |
| script-plan | False | - | Script plan filename run before the distribution is unpacked |
| config-plan | False | - | Config plan filename run after the distribution starts |
| suites | False | - | Space separated suites, overriding the test plan |
| robot-options | False | - | Extra robot command line options (TESTOPTIONS) |
| robot-pass-threshold | False | `100.0` | Fail the job if the robot pass rate is below this percentage |
| robot-unstable-threshold | False | `0.0` | Warn if the robot pass rate is below this percentage |
| job-name | False | - | The JJB job name this run reproduces. Used as the heading of the per-job report, so the run summary is readable without cross-referencing the matrix. |
| results-dir | False | `results` | Used by `mode: report`. Directory holding one subdirectory of downloaded results per job, named after the job. |
| expected-jobs | False | - | Used by `mode: report`. JSON array of the dispatched job objects, so the report covers a job that produced no results instead of dropping it. |
| html-dir | False | - | Used by `mode: report`. When set, publish a self-contained report site here (index.html, report.json, csit-summary.md, plus rebot's report.html and log.html) for GitHub Pages. Empty means the step summary alone. |
| title | False | - | Used by `mode: report`. Heading for the published report. |
| repo-url | False | - | Extra feature repository artifact URL (REPO_URL) |

<!-- markdownlint-enable MD013 -->

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Name | Description |
| ---- | ----------- |
| bundle-url | Resolved karaf distribution URL under test |
| bundle-folder | Extracted distribution directory name |
| odl-system-ip | IP of the first controller node |

<!-- markdownlint-enable MD013 -->

## Node image

`docker/Dockerfile.node` builds the stand-in for the OpenStack `builder` image.
It needs what `common-functions.sh` uses on a node: `sshd`,
`sudo`, `wget`, `unzip`, `netstat`, `sshpass` and a JDK.

## License

Apache-2.0
