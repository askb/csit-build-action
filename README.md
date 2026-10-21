<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🧪 CSIT Build Action

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/csit-build-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/csit-build-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/csit-build-action)
<!-- prettier-ignore-end -->

Run CSIT (Continuous System Integration Test) jobs on GitHub Actions: bring
up a lab of SSH-reachable nodes, run a project's own test command against it,
gate the job on its Robot Framework results and report across a fan-out of
jobs.

The action is project-neutral. Everything project specific lives in the
caller: the node images' packages, the command that deploys and tests the
project, and the environment that command reads. `examples/odl` is a complete
worked example that replaces OpenDaylight's `inttest-csit-1node` /
`inttest-csit-3node` Jenkins jobs; see [its README](examples/odl/README.md).

## Design

A CSIT job on Jenkins booted a set of VMs, ran a project script that deployed
the build under test onto them and ran Robot suites, then published the
results. The action keeps that shape and replaces the parts tied to
Jenkins or OpenStack:

<!-- markdownlint-disable MD013 -->

| step     | mode                                       | what it does                                                                  |
| -------- | ------------------------------------------ | ----------------------------------------------------------------------------- |
| resolve  | `resolve`, or `run` with an artifact input | finds the artifact under test from a URL or Maven coordinates                 |
| lab up   | `lab-up`, `run`                            | starts `project-nodes` + `tools-nodes` nodes and writes `lab.env`             |
| test     | `run`                                      | runs `test-command` with the lab, artifact and `extra-env` in its environment |
| gate     | `run`                                      | judges `robot-output` against the pass thresholds                             |
| lab down | `lab-down`, `run` (always)                 | removes the lab and everything lab-up wrote                                   |
| report   | `report`                                   | one go/no-go table across every dispatched job                                |

<!-- markdownlint-enable MD013 -->

`run` does resolve, lab up, test, gate and lab down in one step.
`lab-up` and `lab-down` split the lab out for jobs that need steps of their
own while the lab is up.

## The test command contract

`test-command` runs under `bash -c` in the workspace. Its environment holds:

<!-- markdownlint-disable MD013 -->

| variable                                                               | meaning                                                    |
| ---------------------------------------------------------------------- | ---------------------------------------------------------- |
| `NUM_PROJECT_SYSTEM`, `PROJECT_SYSTEM_IP`, `PROJECT_SYSTEM_n_IP`       | the project nodes (n from 1)                               |
| `NUM_TOOLS_SYSTEM`, `TOOLS_SYSTEM_IP`, `TOOLS_SYSTEM_n_IP`             | the tools nodes, when `tools-nodes` is above 0             |
| `NUM_<P>_SYSTEM`, `<P>_SYSTEM_IP`, `<P>_SYSTEM_n_IP`                   | the project nodes again under `env-prefix` `<P>`, when set |
| `CSIT_LAB_DIR`, `CSIT_SSH_KEY`, `CSIT_NODE_USER`                       | the lab's private directory, SSH key and login user        |
| `CSIT_NODE_JAVA_HOME`                                                  | the nodes' JDK, when the node image has one                |
| `CSIT_LAB_VARS`                                                        | the lab names lab-up wrote, read by a later lab-up         |
| `ARTIFACT_URL`, `ARTIFACT_FILE`, `ARTIFACT_VERSION`, `ARTIFACT_FOLDER` | the resolved artifact, when the run resolves one           |
| `WORKSPACE`, `CSIT_ACTION_PATH`                                        | the workspace and this action's checkout, for its examples |
| anything in `extra-env`                                                | the caller's own parameters                                |

<!-- markdownlint-enable MD013 -->

`ssh <node-ip>` works as is: lab-up adds a `~/.ssh/config` block for the lab
hosts with the lab key and strict host key checking. The same variables are
in `lab.env` (output `lab-env-file`) and, after `mode: lab-up`, in the
environment of the job's later steps. A second lab-up in the same job empties
any name from `CSIT_LAB_VARS` that the new lab does not set, such as a bare
lab's `CSIT_NODE_JAVA_HOME`, so no test sees the earlier lab's values.

With `robot-output` set (default `output.xml`) the Robot gate decides the
verdict and a non-zero exit from the command warns without failing the
job, matching a Jenkins Robot publisher. Set `robot-output: ""` for a
command that is not Robot based: its exit status is then the verdict.

## Backends

<!-- markdownlint-disable MD013 -->

| backend               | nodes are                         | use for                             |
| --------------------- | --------------------------------- | ----------------------------------- |
| `docker`              | containers on the GitHub runner   | jobs whose suites fit in containers |
| `openstack` (planned) | Heat stack reached over Tailscale | jobs needing real VMs               |

<!-- markdownlint-enable MD013 -->

The action rejects a backend it has no lab scripts for.

Each lab gets an ID unique to the job, exported as `CSIT_LAB_ID` through
`GITHUB_ENV`, so a separate `mode: lab-down` later in the same job removes
that lab and nothing belonging to other jobs on a shared Docker daemon.

## Usage

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
- uses: lfreleng-actions/csit-build-action@v1
  with:
      # Images built from docker/Dockerfile.node, pinned by digest
      node-image: ${{ vars.CSIT_NODE_IMAGE }}
      project-nodes: "1"
      maven-repo-url: https://repo.example.org/snapshots
      group-id: org.example
      artifact-id: example-server
      artifact-version: 1.2.0-SNAPSHOT
      extra-env: |
          SUITES=smoke
      test-command: ./ci/csit.sh
```

`ci/csit.sh` copies `$ARTIFACT_URL` onto `$PROJECT_SYSTEM_IP`, starts it,
runs its Robot suites with `--output output.xml` and exits; the gate takes it
from there.

## Reporting

Jenkins gave each CSIT job a Robot-plugin verdict and mailed the project.
Whether a release ships is a human decision, so the same information
has to be readable on the run itself. `scripts/robot-gate.py` covers both
halves and is the sole parser:

<!-- markdownlint-disable MD013 -->

| level       | who renders it                       | what it shows                                                                                       |
| ----------- | ------------------------------------ | --------------------------------------------------------------------------------------------------- |
| per job     | `mode: run`, at the end of every job | that job's verdict, one row per robot suite, the failing tests, and every test name with its status |
| per fan-out | `mode: report`                       | one go/no-go table across every dispatched job                                                      |

<!-- markdownlint-enable MD013 -->

Both write markdown to `$GITHUB_STEP_SUMMARY`, so the report is on the run page
and needs no artifact download. `mode: report` also writes `csit-summary.md` so
you can paste the table into a release discussion.

The per-job report applies `robot-pass-threshold` /
`robot-unstable-threshold` to `robot-output`. Harnesses often end robot with
`|| true`, so with a `robot-output` set the gate, not the command's exit
status, decides the verdict; otherwise a run in which every test failed could
still report success. The report counts and shows skipped tests but keeps
them out of the pass rate, which keeps the verdict identical to the Jenkins one.

The gate also writes `robot-gate.json` beside `output.xml`, recording the
threshold it applied. Upload it with the job's results and `mode: report`
judges each job against that threshold; without it, a job needs 100%.

A job listed in `expected-jobs` that produced no `output.xml` shows up as an
error row, never dropped: a job that vanishes without trace is the one defect
that would make the whole report untrustworthy. `expected-jobs` accepts the
JSON array the matrix received, or a plain newline-separated list of names.

### Published report

Set `html-dir` on `mode: report` and the action also writes a
self-contained site there, for `actions/upload-pages-artifact`:

```text
site/index.html               landing page: verdict, one row per job
site/report.json              the same data, machine-readable
site/csit-summary.md          the step-summary markdown
site/jobs/<job>/report.html   that job's own Robot report
site/jobs/<job>/log.html      that job's own Robot log, with its resources
```

Drill-downs live under `jobs/`, so a job name never collides with the
site's own files. `actions/upload-pages-artifact` follows symlinks, so
publishing refuses a destination holding any symlink outside the `jobs/`
tree and site files it rebuilds, such as a job's linked `log.html` when
publishing into the results directory, and deletes nothing. In place,
it also refuses a symlink named like a site file or `jobs/`: that is a
job, possibly dangling, the site would overwrite. It also refuses a
destination that is a symlink, sits under one, or has `..` after a
name.

A step summary disappears behind a login and an artifact expires; a release
discussion needs a URL that outlives both.

The per-job drill-down is Robot's own `report.html`, copied in rather than
regenerated: the same page a Jenkins Robot publisher shows. `rebot` could
merge every job into one tree instead, but it names each merged suite from the
robot suite name and those collide across jobs (two suites both called
`Openflowplugin`, no way to tell which job failed), which is useless as a
release gate.

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                     | Required | Default      | Description                                                                                                                                                                                                                                                                                                                                        |
| ------------------------ | -------- | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| mode                     | False    | `run`        | lab-up \| run \| lab-down \| resolve \| report                                                                                                                                                                                                                                                                                                     |
| backend                  | False    | `docker`     | Node provider. Today the action ships 'docker' (runner-local containers); 'openstack' (Heat + Tailscale) is on the roadmap                                                                                                                                                                                                                         |
| project-nodes            | False    | `1`          | Number of nodes running the project under test (an integer, 1 or more). lab-up publishes them as PROJECT_SYSTEM_n_IP                                                                                                                                                                                                                               |
| tools-nodes              | False    | `0`          | Number of tools nodes (traffic generators, simulators and the like), published as TOOLS_SYSTEM_n_IP                                                                                                                                                                                                                                                |
| node-image               | False    | -            | Container image for project nodes (docker backend). Required for lab-up and run; pinned as image@sha256:... or a local image ID. When the image sets JAVA_HOME to a JDK, lab-up passes it on as CSIT_NODE_JAVA_HOME                                                                                                                                |
| tools-image              | False    | -            | Container image for tools nodes (docker backend). Required when tools-nodes is above 0; pinned like node-image                                                                                                                                                                                                                                     |
| tools-privileged         | False    | `false`      | Run tools nodes with --privileged and the host's /lib/modules, which Open vSwitch on the kernel datapath and mininet need. A privileged container is root on the runner, so reserve it for ephemeral runners                                                                                                                                       |
| env-prefix               | False    | `PROJECT`    | Extra name for the project nodes' variables, for harnesses that already read their own: with ODL, lab-up also publishes NUM_ODL_SYSTEM, ODL_SYSTEM_IP and ODL_SYSTEM_n_IP. Must match `[A-Z][A-Z0-9_]*`, not be TOOLS and not start with GITHUB, RUNNER or LD                                                                                      |
| node-prompt              | False    | -            | Shell prompt (PS1) for the node user, for harnesses that wait for a particular prompt over SSH. Empty leaves the image's default                                                                                                                                                                                                                   |
| artifact-url             | False    | -            | URL of the artifact to test, laid out Maven-style as `.../<artifactId>/<version>/<file>` with no query or fragment. Alternative to the Maven inputs                                                                                                                                                                                                |
| maven-repo-url           | False    | -            | Maven repository root to resolve the artifact from                                                                                                                                                                                                                                                                                                 |
| group-id                 | False    | -            | Maven groupId of the artifact, for example org.example                                                                                                                                                                                                                                                                                             |
| artifact-id              | False    | -            | Maven artifactId of the artifact                                                                                                                                                                                                                                                                                                                   |
| artifact-version         | False    | -            | Artifact version. A -SNAPSHOT version resolves to the newest timestamped build. Leave empty to read it from version-pom-url                                                                                                                                                                                                                        |
| version-pom-url          | False    | -            | URL of a pom.xml whose /project/version is the version to test, for tracking a branch's current snapshot                                                                                                                                                                                                                                           |
| artifact-extension       | False    | `zip`        | File extension (Maven packaging) of the artifact                                                                                                                                                                                                                                                                                                   |
| test-command             | False    | -            | Bash command line that deploys and tests the project on the lab. Runs in the workspace with the lab's variables (see README), ARTIFACT_*, extra-env and CSIT_ACTION_PATH in its environment. Required for run                                                                                                                                      |
| extra-env                | False    | -            | Extra environment for test-command, one NAME=VALUE per line. The action skips blank lines and lines starting with #, and refuses PATH, IFS, HOME, ENV, BASH_ENV, SHELLOPTS, BASHOPTS, PS4, `LD_*`, `GITHUB_*`, `RUNNER_*`, WORKSPACE and CSIT_ACTION_PATH. The values reach test-command alone, never the action's own scripts                     |
| robot-output             | False    | `output.xml` | Robot Framework output.xml the test command writes, relative to the workspace; the action judges it against the pass thresholds. Empty makes the test command's exit status the verdict                                                                                                                                                            |
| robot-pass-threshold     | False    | `100.0`      | Fail the job if the robot pass rate is below this percentage                                                                                                                                                                                                                                                                                       |
| robot-unstable-threshold | False    | `0.0`        | Warn if the robot pass rate is below this percentage                                                                                                                                                                                                                                                                                               |
| job-name                 | False    | -            | Name of the job this run is, used as the heading of its report so the run summary is readable without cross-referencing the matrix.                                                                                                                                                                                                                |
| results-dir              | False    | `results`    | Used by `mode: report`. Directory holding one subdirectory of downloaded results per job, named after the job.                                                                                                                                                                                                                                     |
| expected-jobs            | False    | -            | Used by `mode: report`. JSON array of the dispatched job objects, so the report covers a job that produced no results instead of dropping it.                                                                                                                                                                                                      |
| html-dir                 | False    | -            | Used by `mode: report`. When set, publish a self-contained report site here (index.html, report.json, csit-summary.md, plus each job's own report.html and log.html under jobs/) for GitHub Pages. Empty means the step summary alone.                                                                                                             |
| title                    | False    | -            | Used by `mode: report`. Heading for the published report.                                                                                                                                                                                                                                                                                          |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Name              | Description                                                     |
| ----------------- | --------------------------------------------------------------- |
| artifact-url      | Resolved URL of the artifact under test                         |
| artifact-version  | Resolved version of the artifact under test                     |
| artifact-folder   | `<artifactId>-<version>`, the directory such archives unpack to |
| project-system-ip | IP of the first project node                                    |
| lab-env-file      | Path of the lab.env file describing the lab                     |

<!-- markdownlint-enable MD013 -->

## Node images

`docker/Dockerfile.node` has two targets. `node` is a minimal SSH host:
`sshd`, `sudo`, `procps` and `iproute2`. `tools` builds on it. Everything
else a project's suites need comes from package files the project passes as
a named build context:

```text
<dir>/node.txt    Ubuntu packages for both targets, one per line
<dir>/tools.txt   Ubuntu packages for the tools target
<dir>/node.sh     optional, runs as root after node.txt
<dir>/tools.sh    optional, runs as root after tools.txt
```

A JDK is a package like any other; when the list includes one,
`/usr/lib/jvm/csit-java` points at it and lab-up passes it on as
`CSIT_NODE_JAVA_HOME`. Without the build context the build yields the bare lab image.

```bash
for target in node tools; do
  docker build -f docker/Dockerfile.node --target "$target" \
    --build-context packages=examples/odl/packages \
    -t "csit-$target" docker
done
tests/test-node-tools.sh csit-tools examples/odl/required-binaries.txt
```

`tests/test-node-tools.sh` checks a built image against a project's list of
the binaries its suites shell out to, so a missing one fails the build rather
than a suite setup.

The action has no default images and never builds one at run time:
callers pass `node-image` (and `tools-image` when `tools-nodes` is above
0), and lab-up fails if the pull fails. lab-up refuses a tag: it takes
`name@sha256:<digest>`, or a local image ID (`sha256:<id>`) for a build
on the runner.

### Supply chain

- Both stages pin the `ubuntu:22.04` base by digest, and
  Dependabot (`docker` ecosystem on `/docker`) bumps it weekly.
- hadolint runs in pre-commit with `.hadolint.yaml`, which records the
  justification for each ignored rule.
- The `Node images` CI job builds both targets with the OpenDaylight
  package set plus the bare image, checks them, generates an SBOM for
  each of the three and fails on High or Critical Grype findings in any.
  It uploads the SBOMs and the scan results as artifacts.
- A package script that builds from source removes its build
  dependencies in the same layer; `examples/odl/packages/tools.sh` shows
  how.

### Security

- `sshd` needs root to bind port 22 and switch to the login user, so
  the images run as root. No host keys ship in an image: each container
  generates its own at start.
- lab-up creates a fresh ed25519 key pair and `known_hosts` per lab
  under `RUNNER_TEMP`. Its `~/.ssh/config` block sets
  `StrictHostKeyChecking yes` and `ForwardAgent no` for the lab hosts
  and sits before any
  existing configuration, and lab-down removes it. The runner's
  `~/.ssh/id_rsa` is never read or written.
- Tools nodes run unprivileged by default. `tools-privileged: true` adds
  `--privileged` and mounts `/lib/modules` (`ro`) for the OVS kernel
  datapath. A privileged container is root on the runner, so reserve
  it for ephemeral runners.
- The action parses `extra-env` as data, never evaluating it, and refuses
  names that would change how the shell or the runner behaves. It passes
  the values to `test-command` alone, so they cannot alter the action's
  own scripts.
- `robot-output` must resolve inside the workspace, checked by name and
  through symlinked directories, before the action deletes stale results
  and again before the gate writes its verdict. The gate renames a new
  verdict file into place, so it never writes through a planted symlink.
- Artifact and Maven URLs must be `http(s)`; plain `http` warns.

## License

Apache-2.0
