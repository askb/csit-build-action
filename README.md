<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# CSIT Build Action

Run OpenDaylight-style CSIT (Continuous System Integration Test) jobs on GitHub
Actions, replacing the `inttest-csit-1node` / `inttest-csit-3node` Jenkins Job
Builder templates in `releng/builder`.

## Design

The CSIT logic is **not** reimplemented. `releng/builder`'s own scripts stay the
single source of truth and are executed unmodified:

| releng/builder script | role |
| --- | --- |
| `jjb/integration/common-functions.sh` | karaf deploy/configure/collect helpers |
| `jjb/integration/integration-install-robotframework.sh` | robot venv + requirements |
| `jjb/integration/integration-deploy-controller-run-test.sh` | 1-node deploy + robot |
| `jjb/integration/integration-start-cluster-run-test.sh` | 3-node deploy + robot |
| `global-jjb/jenkins-init-scripts/lf-env.sh` | `lf-activate-venv` |

Only the pieces that were bound to Jenkins or OpenStack are replaced:

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

The contract the robot suites depend on is unchanged: a set of SSH-reachable
hosts exposed as `ODL_SYSTEM_n_IP` / `TOOLS_SYSTEM_n_IP`.

## Backends

| backend | nodes are | use for |
| --- | --- | --- |
| `docker` | containers on the GitHub runner | jobs with no mininet/OVS requirement |
| `openstack` | Heat stack reached over Tailscale | jobs needing real mininet/OVS |

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

| level | who renders it | what it shows |
| --- | --- | --- |
| per job | `mode: run`, at the end of every job | that job's verdict, one row per robot suite, the failing tests, and every test name with its status |
| per fan-out | `mode: report` | one go/no-go table across every job that was dispatched |

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

Set `html-dir` on `mode: report` and the action additionally writes a
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
regenerated — it is exactly what ODL reads on Jenkins today. `rebot` could
merge every job into one tree instead, but it names each merged suite from the
robot suite name and those collide across jobs (two suites both called
`Openflowplugin`, no way to tell which job failed), which is useless as a
release gate.

## Inputs

See [`action.yaml`](action.yaml). Every input maps to a JJB CSIT job parameter,
so a JJB job definition translates field for field.

## Node image

`docker/Dockerfile.node` builds the stand-in for the OpenStack `builder` image.
It only needs what `common-functions.sh` actually uses on a node: `sshd`,
`sudo`, `wget`, `unzip`, `netstat`, `sshpass` and a JDK.

## License

Apache-2.0
