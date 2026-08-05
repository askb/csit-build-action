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

## Inputs

See [`action.yaml`](action.yaml). Every input maps to a JJB CSIT job parameter,
so a JJB job definition translates field for field.

## Node image

`docker/Dockerfile.node` builds the stand-in for the OpenStack `builder` image.
It only needs what `common-functions.sh` actually uses on a node: `sshd`,
`sudo`, `wget`, `unzip`, `netstat`, `sshpass` and a JDK.

## License

Apache-2.0
