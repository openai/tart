## Installation

The easiest way to install Orchard CLI is through the [Homebrew](https://brew.sh/):

```shell
brew install cirruslabs/cli/orchard
```

Binaries and packages for other architectures can be found in [GitHub Releases](https://github.com/openai/orchard/releases).

## Setting up a context

The first step after installing the Orchard CLI is to configure its context. Configuring context is like pairing with the specified Orchard Controller, so that the commands like `orchard create vm`, `orchard ssh vm` will work.

To configure a context, `orchard context` has a subfamily of commands:

* `orchard context create <CONTROLLER ADDRESS>` — creates a new context to communicate with Orchard Controller available on the specified address
* `orchard context default <CONTROLLER ADDRESS>` — sets a context with a given Orchard Controller address as default (in case there's more than one context configured)
* `orchard context list` — lists all the configured contexts, indicating the default one
* `orchard context delete <CONTROLLER ADDRESS>` — deletes a context for the specified Orchard Controller address

Most of the time, you'll only need the `orchard context create`. For example, if you've deployed your Orchard Controller to `orchard-controller.example.com`, a new context can be configured like so:

```shell
orchard context create orchard-controller.example.com
```

`orchard context create` assumes port 6120 by default, so if you use a different port for the Orchard Controller, simply specify the port explicitly:

```shell
orchard context create orchard-controller.example.com:8080
```

When creating a new context you will be prompted for the service account name and token, which can be obtained from:

* `orchard controller run` logs
    * if this is a first start
* `orchard get service-account`
    * from an already configured Orchard CLI

## Using labels when creating VMs

Labels are useful if you want to restrict scheduling of a VM to workers whose labels include a subset of the VM's specified labels.

For example, you might have an Orchard Cluster consisting of the following workers:

* Mac Minis (`orchard worker run --labels location=DC1-R12-S4,model=macmini`)
* Mac Studios (`orchard worker run --labels location=DC1-R18-S8,model=macstudio`)

To create and run a VM specifically on Mac Studio machines, pass the `--labels` command-line argument to `orchard create vm` when creating a VM:

```shell
orchard create vm --labels model=macstudio <NAME>
```

When processing this VM, the scheduler will only place it on available Mac Studio workers.

## Using resources when creating VMs

Resources are useful if you want to restrict scheduling of a VM to workers that still have enough of the specified resource to fit the VM's requirements.

The difference between the labels is that the resources are finite and are automatically accounted by the scheduler.

To illustrate this with an example, let's say you have an Orchard Cluster consisting of the following workers:

* Mac Mini with 1 Gbps bandwidth (`orchard worker run --resources bandwidth-mbps=1000`)
* Mac Studio with 10 Gbps bandwidth (`orchard worker run --resources bandwidth-mbps=10000`)

VM created using the command below will only be scheduled on a Mac Studio with 10 Gbps bandwidth:

```shell
orchard create vm --resources bandwidth-mbps=7500 <NAME>
```

However, after this VM is scheduled, the 10 Gbps Mac Studio will only be able to accommodate one more VM (due to internal Apple EULA limit for macOS virtualization) with `bandwidth-mbps=2500` or less.

After the VM finishes, the unused resources will be available again.

## Automatic resources

In addition to manually specifying resources when starting a worker, the following resources are discovered and set automatically by the worker for convenience:

* `org.cirruslabs.logical-cores` — number of logical cores on the host
* `org.cirruslabs.memory-mib` — total memory in MiB (mebibytes) on the host

Note that the values for these resources are scraped only once at worker startup.
