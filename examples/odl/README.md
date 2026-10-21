<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# OpenDaylight CSIT

A complete use of `csit-build-action` that replaces OpenDaylight's
`inttest-csit-1node` and `inttest-csit-3node` Jenkins Job Builder templates
in `releng/builder`.

<!-- markdownlint-disable MD013 -->

| file                                      | role                                                                      |
| ----------------------------------------- | ------------------------------------------------------------------------- |
| `csit-run.sh`                             | the test command: stages builder's environment and runs builder's scripts |
| `packages/node.txt`, `packages/tools.txt` | Ubuntu packages for the controller and tools images                       |
| `packages/tools.sh`                       | builds `cbench` from a pinned source and removes its build tree           |
| `required-binaries.txt`                   | what the suites shell out to, checked by `tests/test-node-tools.sh`       |

<!-- markdownlint-enable MD013 -->

## Design

The CSIT logic is **not** reimplemented. `releng/builder`'s own scripts stay
the single source of truth, and `csit-run.sh` runs them unmodified:

<!-- markdownlint-disable MD013 -->

| releng/builder script                                       | role                                   |
| ----------------------------------------------------------- | -------------------------------------- |
| `jjb/integration/common-functions.sh`                       | karaf deploy/configure/collect helpers |
| `jjb/integration/integration-install-robotframework.sh`     | robot venv + requirements              |
| `jjb/integration/integration-configure-clustering.sh`       | 3-node cluster configuration           |
| `jjb/integration/integration-deploy-controller-run-test.sh` | 1-node deploy + robot                  |
| `jjb/integration/integration-start-cluster-run-test.sh`     | 3-node deploy + robot                  |
| `global-jjb/jenkins-init-scripts/lf-env.sh`                 | `lf-activate-venv`                     |

<!-- markdownlint-enable MD013 -->

The pieces tied to Jenkins or OpenStack map onto the action:

<!-- markdownlint-disable MD013 -->

| Jenkins / JJB                                                      | replacement                                                    |
| ------------------------------------------------------------------ | -------------------------------------------------------------- |
| `lf-stack-create` (Heat)                                           | lab-up, with `env-prefix: ODL` for the `ODL_SYSTEM_n_IP` names |
| `integration-get-slave-addresses.sh`                               | the lab variables lab-up puts in the environment               |
| `copy-common-functions.sh` (`openstack stack show`)                | `csit-run.sh`, from the lab's node list                        |
| `integration-set-variables.sh` + `integration-detect-variables.sh` | the action's artifact resolver, then `csit-run.sh`             |
| `inject` build steps                                               | `extra-env`                                                    |
| `lf-stack-delete`                                                  | lab-down                                                       |
| robot publisher, `lf-infra-publish`                                | the action's Robot gate + `actions/upload-artifact`            |

<!-- markdownlint-enable MD013 -->

## Images

```bash
for target in node tools; do
  docker build -f docker/Dockerfile.node --target "$target" \
    --build-context packages=examples/odl/packages \
    -t "ghcr.io/opendaylight/csit-$target" docker
done
tests/test-node-tools.sh ghcr.io/opendaylight/csit-tools
```

`node.txt` installs `openjdk-21-jdk-headless`; change it for a stream that
needs another JDK.

## Usage

```yaml
# builder's jjb/integration scripts plus the global-jjb submodule for lf-env.sh
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
      repository: opendaylight/releng-builder
      ref: master
      path: builder
      submodules: true
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
      repository: opendaylight/integration-test
      ref: master # suites branch on DISTROSTREAM, not git
      path: test
- uses: lfreleng-actions/csit-build-action@v1
  with:
      node-image: ${{ vars.CSIT_NODE_IMAGE }}
      project-nodes: "1"
      env-prefix: ODL
      # Robot's SSHLibrary waits for a prompt ending in '>'
      node-prompt: '[\u@\h \W]> '
      # The newest snapshot of the integration distribution's branch
      maven-repo-url: https://nexus.opendaylight.org/content/repositories/opendaylight.snapshot
      group-id: org.opendaylight.integration
      artifact-id: karaf
      version-pom-url: https://raw.githubusercontent.com/opendaylight/integration-distribution/stable/vanadium/pom.xml
      job-name: daexim-csit-1node-basic-all-vanadium
      test-command: '"$CSIT_ACTION_PATH/examples/odl/csit-run.sh"'
      extra-env: |
          CSIT_SCRIPTS_DIR=builder/jjb/integration
          CSIT_LF_ENV=builder/global-jjb/jenkins-init-scripts/lf-env.sh
          DISTROSTREAM=vanadium
          DISTROBRANCH=stable/vanadium
          CONTROLLERFEATURES=odl-daexim-all,odl-netconf-topology,odl-jolokia
          TESTPLAN=daexim-basic.txt
          STREAMTESTPLAN=daexim-basic-vanadium.txt
```

`csit-run.sh` needs `project-nodes` 1 or 3, the two shapes builder's
templates support.

## JJB parameters

A JJB CSIT job translates field for field. The lab and the artifact map to
action inputs; every other job parameter is an `extra-env` line under the
name builder's scripts already read.

<!-- markdownlint-disable MD013 -->

| JJB                                                    | action                              | default in `csit-run.sh` |
| ------------------------------------------------------ | ----------------------------------- | ------------------------ |
| `VM_0_COUNT`                                           | `project-nodes` (1 or 3)            | -                        |
| `VM_1_COUNT`                                           | `tools-nodes`                       | -                        |
| `BUNDLE_URL`                                           | `artifact-url`, or the Maven inputs | -                        |
| `DISTROSTREAM`                                         | `extra-env`                         | required                 |
| `TESTPLAN`                                             | `extra-env`                         | required                 |
| `DISTROBRANCH`                                         | `extra-env`                         | `master`                 |
| `KARAF_VERSION`                                        | `extra-env`                         | `karaf4`                 |
| `JDKVERSION`                                           | `extra-env`                         | -                        |
| `CONTROLLERFEATURES`                                   | `extra-env`                         | -                        |
| `CONTROLLERSCOPE`                                      | `extra-env`                         | &#111;nly                |
| `CONTROLLERMAXMEM`                                     | `extra-env`                         | `CONTROLLERMEM`, `2048m` |
| `CONTROLLERDEBUGMAP`                                   | `extra-env`                         | -                        |
| `USEFEATURESBOOT`                                      | `extra-env`                         | `True`                   |
| `ELASTICSEARCHATTRIBUTE`                               | `extra-env`                         | `disabled`               |
| `IS_KARAF_APPL`                                        | `extra-env`                         | `True`                   |
| `STREAMTESTPLAN`, `SCRIPTPLAN`, `CONFIGPLAN`, `SUITES` | `extra-env`                         | -                        |
| `TESTOPTIONS`                                          | `extra-env`                         | -                        |
| `REPO_URL`                                             | `extra-env`                         | -                        |
| `CONTROLLERMEM`                                        | `extra-env`                         | = `CONTROLLERMAXMEM`     |
| `KARAF_PROJECT`                                        | `extra-env`                         | from the artifact path   |
| `NEXUSURL_PREFIX`                                      | `extra-env`                         | the artifact's host      |
| `GERRIT_PROJECT`                                       | `extra-env`                         | `integration/test`       |
| `GERRIT_BRANCH`                                        | `extra-env`                         | `DISTROBRANCH`           |
| `GERRIT_REFSPEC`                                       | `extra-env`                         | `refs/heads/` + branch   |
| `robot-pass-threshold`, `robot-unstable-threshold`     | the action inputs of the same name  | `100.0`, `0.0`           |

<!-- markdownlint-enable MD013 -->

`csit-run.sh` also reads `CSIT_SCRIPTS_DIR` (builder's `jjb/integration`,
required), `CSIT_LF_ENV` (global-jjb's `jenkins-init-scripts/lf-env.sh`,
required), `CSIT_TEST_DIR` (the integration/test checkout, default `test`)
and `CSIT_NODE_JAVA_HOME`, which lab-up sets when the node image has a
JDK; without one it stops.

builder's `common-functions.sh` sets `CONTROLLERMEM` from `CONTROLLERMAXMEM`.
`csit-run.sh` matches this: a lone `CONTROLLERMEM` becomes the heap limit, and
`CONTROLLERMAXMEM` wins when a caller sets both.
