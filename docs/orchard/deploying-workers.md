## Obtain a Boostrap Token

First, create a service account with a minimal set of roles (`compute:read` and `compute:write`) required for proper Worker functioning:

```bash
orchard create service-account worker-pool-m1 --roles "compute:read" --roles "compute:write"
```

Then, generate a Bootstrap Token for this service account:

```shell
orchard get bootstrap-token worker-pool-m1
```

We will reference the value of the Bootstrap Token generated here as `${BOOTSTRAP_TOKEN}` below.

Further, we assume that Orchard controller is available on `orchard.example.com`

## Deployment Methods

While you can always run `orchard worker run` manually with the required arguments, this method of deploying the Worker is not recommended.

Instead, we've listed a more persistent methods of a Worker deployment below.

### launchd

[launchd](https://launchd.info/) is an init system for macOS that manages daemons, agents and other background processes.

In this deployment method, we'll create a new job definition file for the launchd to manage on its behalf.

To begin, first install Orchard:

```shell
brew install openai/tools/orchard
```

Ensure that the following command:

```shell
which orchard
```

...yields `/opt/homebrew/bin/orchard`. If not, you'll need to replace all of the occurences of `/opt/homebrew/bin/orchard` in the job definition below.

Then, create a launchd job definition in `/Library/LaunchDaemons/org.cirruslabs.orchard.worker.plist` with the following contents:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>org.cirruslabs.orchard.worker</string>
    <key>Program</key>
    <string>/opt/homebrew/bin/orchard</string>
    <key>ProgramArguments</key>
    <array>
      <string>/opt/homebrew/bin/orchard</string>
      <string>worker</string>
      <string>run</string>
      <string>--user</string>
      <string>admin</string>
      <string>--bootstrap-token</string>
      <string>${BOOTSTRAP_TOKEN}</string>
      <string>orchard.example.com</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>/var/empty</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/admin/orchard-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/admin/orchard-launchd.log</string>
  </dict>
</plist>
```

This assumes that your macOS user on the host is named `admin`. If not, change all occurrences of `admin` in the job definition above to `$USER`.

Finally, change the `orchard.example.com` to the FQDN or an IP-address of your Orchard Controller.

Now, you can start the job:

```shell
launchctl load -w /Library/LaunchDaemons/org.cirruslabs.orchard.worker.plist
```

### Ansible

If you have a set of machines that you want to use as Orchard Workers, you can use [Ansible](https://docs.ansible.com/) to configure them.

We've created the [cirruslabs/ansible-orchard](https://github.com/cirruslabs/ansible-orchard) repository with a basic Ansible playbook for convenient setup.

To use it, clone it locally:

```shell
git clone https://github.com/cirruslabs/ansible-orchard.git
cd ansible-orchard/
```

Make sure that the Ansible Galaxy dependencies are installed:

```shell
ansible-galaxy install -r requirements.yml
```

Then, edit the `production-pool` file and populate the following fields:

* `hosts` — replace `worker-1.hosts.internal` with your worker FQDN or IP-address and add more hosts if needed
* `ansible_user` — set it macOS user on the host for the SSH to work
* `orchard_worker_user` — set it macOS user on the host under which the Worker will run, e.g. `admin`
* `orchard_worker_controller_url` — set it to FQDN or an IP-address of your Orchard Controller, for example, `orchard.example.com`
* `orchard_worker_bootstrap_token` — set it to `${BOOTSTRAP_TOKEN}` we've generated above

Deploy the playbook:

```shell
ansible-playbook --inventory-file production-pool --ask-pass playbook-workers.yml
```
