Tart is great for running workloads on a single machine, but what if you have more than one computer at your disposal
and
a couple of VMs is not enough anymore for your needs? This is where [Orchard](https://github.com/openai/orchard)
comes in to play!

It allows you to orchestrate multiple Tart-capable hosts from either an Orchard CLI (which we demonstrate below)
or [through the API](integration-guide.md).

The easiest way to start is to run Orchard in local development mode:

```shell
brew install openai/tools/orchard
orchard dev
```

This will run an Orchard Controller and an Orchard Worker in a single process on your local machine, allowing you to
test both the CLI functionality and the API from a tool like cURL or programming language of choice, without the need to
authenticate requests.

Note that in production deployments, these two components are started separately and enable security by default. Please
refer to [Deploying Controller](deploying-controller.md) and [Deploying Workers](deploying-workers.md) for
more information.

## Creating Virtual Machines

Now, let's create a Virtual Machine:

```shell
orchard create vm --image ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base
```

You can check a list of VM resources to see if the Virtual Machine we've created above is already running:

```shell
orchard list vms
```

## Accessing Virtual Machines

Orchard has an ability to do port forwarding that `ssh` and `vnc` commands are built on top of. All port forwarding
connections are done via the Orchard Controller instance which "proxies" a secure connection to the Orchard Workers.

Therefore, your workers can be located under a stricter firewall that only allows connections to the Orchard Controller
instance. Orchard Controller instance is secured by default and all API calls are authenticated and authorized.

### SSH

To SSH into a VM, use the `orchard ssh` command:

```shell
orchard ssh vm tahoe-base
```

You can specify the `--username` and `--password` flags to specify the username/password pair to use for the SSH
protocol. By default, `admin`/`admin` is used.

You can also execute remote commands instead of spawning a login shell, similarly to how OpenSSH's `ssh` command accepts
a command argument:

```shell
orchard ssh vm tahoe-base "uname -a"
```

You can execute scripts remotely this way, by telling the remote command-line interpreter to read from the standard
input and using the redirection operator as follows:

```shell
orchard ssh vm tahoe-base "bash -s" < script.sh
```

### VNC

Similarly to `ssh` command, you can use `vnc` command to open Screen Sharing into a remote VM:

```shell
orchard vnc vm tahoe-base
```

You can specify the `--username` and `--password` flags to specify the username/password pair to use for the VNC
protocol. By default, `admin`/`admin` is used.

## Deleting Virtual Machines

The following command will delete the VM we've created above and clean-up the resources associated with it:

```shell
orchard delete vm tahoe-base
```

## Environment variables

In addition to controlling the Orchard via the CLI arguments, there are environment variables that may be beneficial
both when automating Orchard and in daily use:

| Variable name                   | Description                                                                                                      |
|---------------------------------|------------------------------------------------------------------------------------------------------------------|
| `ORCHARD_HOME`                  | Override Orchard's home directory. Useful when running multiple Orchard instances on the same host and testing.  |
| `ORCHARD_URL`                   | Override controller URL on a per-command basis.                                                                  |
| `ORCHARD_SERVICE_ACCOUNT_NAME`  | Override service account name (used for controller API auth) on a per-command basis.                             |
| `ORCHARD_SERVICE_ACCOUNT_TOKEN` | Override service account token (used for controller API auth) on a per-command basis.                            |
