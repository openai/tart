---
title: Cirrus CLI
description: Tool for running isolated tasks reproducibly in any environment with a simple YAML configuration.
---

# Cirrus CLI

Tart itself is only responsible for managing virtual machines, but Cirrus Labs built Tart support into a tool called
[Cirrus CLI](https://github.com/cirruslabs/cirrus-cli), a command line tool with
one configuration format to execute common CI steps (run a script, cache a folder, etc.) locally or in any CI system.
We built Cirrus CLI to solve "But it works on my machine!" problem.

Here is an example of a `.cirrus.yml` configuration file which will start a Tart VM, will copy over working directory and
will run scripts and [other instructions](https://cirrus-ci.org/guide/writing-tasks/#supported-instructions) inside the virtual machine:

```yaml
task:
  name: hello
  macos_instance:
    # can be a remote or a local virtual machine
    image: ghcr.io/cirruslabs/macos-tahoe-base:latest
  hello_script:
    - echo "Hello from within a Tart VM!"
    - echo "Here is my CPU info:"
    - sysctl -n machdep.cpu.brand_string
    - sleep 15
```

Put the above `.cirrus.yml` file in the root of your repository and run it with the following command:

```bash
brew install cirruslabs/cli/cirrus
cirrus run
```

![](../assets/images/TartCirrusCLI.gif)

[Cirrus CI](https://cirrus-ci.org/) already leverages Tart to power its macOS cloud infrastructure. The `.cirrus.yml`
config from above will just work in Cirrus CI and your tasks will be executed inside Tart VMs in our cloud.

**Note:** Cirrus CI only allows [images managed and regularly updated by Cirrus Labs](https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos).

## Retrieving artifacts from within Tart VMs

In many cases there is a need to retrieve particular files or a folder from within a Tart virtual machine.
For example, the below `.cirrus.yml` configuration defines a single task that builds a `tart` binary and
exposes it via [`artifacts` instruction](https://cirrus-ci.org/guide/writing-tasks/#artifacts-instruction):

```yaml
task:
  name: Build
  macos_instance:
    image: ghcr.io/cirruslabs/macos-tahoe-xcode:latest
  build_script: swift build --product tart
  binary_artifacts:
    path: .build/debug/tart
```

Running Cirrus CLI with `--artifacts-dir` will write defined `artifacts` to the provided local directory on the host:

```bash
cirrus run --artifacts-dir artifacts
```

Note that all retrieved artifacts will be prefixed with the associated task name and `artifacts` instruction name.
For the example above, `tart` binary will be saved to `$PWD/artifacts/Build/binary/.build/debug/tart`.
