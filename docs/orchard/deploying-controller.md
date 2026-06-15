## Introduction

Compared to Worker, which can only be deployed on a macOS machine, Controller can be also deployed on Linux.

In fact, we've made a [container image](https://github.com/orgs/cirruslabs/packages/container/package/orchard) to ease deploying the Controller in container-native environments such as Kubernetes.

Another thing to keep in mind that Orchard API is secured by default: all requests must be authenticated with the credentials of a service account. When you first run Orchard Controller, a `bootstrap-admin` service account will be created automatically and credentials will be printed to the standard output.

If you already have a token in mind that you want to use for the `bootstrap-admin` service account, or you've got locked out and want this service account with a well-known password back, you can set the `ORCHARD_BOOTSTRAP_ADMIN_TOKEN` when running the controller.

For example to use a secure, random value:

```bash
ORCHARD_BOOTSTRAP_ADMIN_TOKEN=$(openssl rand -hex 32) orchard controller run
```

## Customization

Note that all the [Deployment Methods](#deployment-methods) essentially boil down to starting an `orchard controller run` command and keeping it alive.

This means that by introducing additional command-line arguments, you can customize the Orchard Controller's behavior. Below, we list some of the common scenarios.

### Customizing listening port

* `--listen` — address to listen on (default `:6120`)

### Customizing TLS

* `--controller-cert` — use the controller certificate from the specified path instead of the auto-generated one (requires --controller-key)
* `--controller-key` — use the controller certificate key from the specified path instead of the auto-generated one (requires --controller-cert)
* `--insecure-no-tls` — disable TLS, making all connections to the controller unencrypted
    * useful when deploying Orchard Controller behind a load balancer/ingress controller

### Built-in SSH server

Orchard Controller can act as a simple SSH server that port-forwards connections to the VMs running in the Orchard Cluster.

This way you can completely skip the Orchard API when connecting to a given VM and only use the SSH client:

```shell
ssh -J <service account name>@orchard-controller.example.com <VM name>
```

To enable this functionality, pass `--listen-ssh` command-line argument to the `orchard controller run` command, for example:

```ssh
orchard controller run --listen-ssh 6122
```

Here's other command-line arguments associated with this functionality:

* `--ssh-host-key` — use the SSH private host key from the specified path instead of the auto-generated one
* `--insecure-ssh-no-client-auth` — allow SSH clients to connect to the controller's SSH server without authentication, thus only authenticating on the target worker/VM's SSH server
    * useful when you already have strong credentials on your VMs, and you want to share these VMs to others without additionally giving out Orchard Cluster credentials

Check out our [Jumping through the hoops: SSH jump host functionality in Orchard](../blog/posts/2024-06-20-jumping-through-the-hoops.md) blog post for more information.

## Deployment Methods

While you can always start `orchard controller run` manually with the required arguments, this method is not recommended due to lack of persistence.

In the following sections you'll find several examples of how to run Orchard Controller in various environments in a more persistent way. Feel free to submit PRs with more examples.

### Google Compute Engine

An example below will deploy a single instance of Orchard Controller in Google Cloud Compute Engine in `us-central1` region.

First, let's create a static IP address for our instance:

```bash
gcloud compute addresses create orchard-ip --region=us-central1
export ORCHARD_IP=$(gcloud compute addresses describe orchard-ip --format='value(address)' --region=us-central1)
```

Then, ensure that there exist a firewall rule targeting `https-server` tag and allowing access to TCP port 443. If that's not the case, create one:

```shell
gcloud compute firewall-rules create default-allow-https --direction=INGRESS --priority=1000 --network=default --action=ALLOW --rules=tcp:443 --source-ranges=0.0.0.0/0 --target-tags=https-server
```

Once we have the IP address and the firewall rule set up, we can create a new instance with Orchard Controller running inside a container:

```bash
gcloud compute instances create-with-container orchard-controller \
  --machine-type=e2-micro \
  --zone=us-central1-a \
  --image-family cos-stable \
  --image-project cos-cloud \
  --tags=https-server \
  --address=$ORCHARD_IP \
  --container-image=ghcr.io/cirruslabs/orchard:latest \
  --container-env=PORT=443 \
  --container-env=ORCHARD_BOOTSTRAP_ADMIN_TOKEN=$ORCHARD_BOOTSTRAP_ADMIN_TOKEN \
  --container-mount-host-path=host-path=/home/orchard-data,mode=rw,mount-path=/data
```

Now you can create a new context for your local client:

```bash
orchard context create --name production \
  --service-account-name bootstrap-admin \
  --service-account-token $ORCHARD_BOOTSTRAP_ADMIN_TOKEN \
  https://$ORCHARD_IP:443
```

And select it as the default context:

```bash
orchard context default production
```

### Kubernetes (GKE, EKS, etc.)

The easiest way to run Orchard Controller on Kubernetes is to expose it through the `LoadBalancer` service.

This way no fiddling with the TLS certificates and HTTP proxying is needed, and most cloud providers will allocate a ready-to-use IP-address that can directly used in `orchard context create` and `orchard worker run` commands, or additionally assigned to a DNS domain name for a more memorable hostname.

Do deploy on Kubernetes, only three resources are needed:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: orchard-controller
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  # Uncomment this when deploying on Amazon's EKS and
  # change to the desired storage class name if needed
  # storageClassName: gp2
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: orchard-controller
spec:
  serviceName: orchard-controller
  replicas: 1
  selector:
    matchLabels:
      app: orchard-controller
  template:
    metadata:
      labels:
        app: orchard-controller
    spec:
      containers:
        - name: orchard-controller
          image: ghcr.io/cirruslabs/orchard:latest
          volumeMounts:
            - mountPath: /data
              name: orchard-controller
      volumes:
        - name: orchard-controller
          persistentVolumeClaim:
            claimName: orchard-controller
---
apiVersion: v1
kind: Service
metadata:
  name: orchard-controller
spec:
  selector:
    app: orchard-controller
  ports:
    - protocol: TCP
      port: 6120
      targetPort: 6120
  type: LoadBalancer
```

Once deployed, the bootstrap credentials will be printed to the standard output. You can inspect them by running `kubectl logs deployment/orchard-controller`.

The resources above ensure that Controller's database is stored in a persistent storage and survives restats.

You can further allocate a static IP address and use it by adding annotations to the `Service` resource. Here's how to do that:

* on Google's GKE: <https://cloud.google.com/kubernetes-engine/docs/concepts/service-load-balancer-parameters#spd-static-ip>
* on Amazon's EKS: <https://kubernetes.io/docs/reference/labels-annotations-taints/#service-beta-kubernetes-io-aws-load-balancer-eip-allocations>

### systemd service on Debian-based distributions

This should work for most Debian-based distributions like Debian, Ubuntu, etc.

Firstly, make sure that the APT transport for downloading packages via HTTPS and common X.509 certificates are installed:

```shell
sudo apt-get update && sudo apt-get -y install apt-transport-https ca-certificates
```

Then, add the Cirrus Labs repository:

```shell
echo "deb [trusted=yes] https://apt.fury.io/cirruslabs/ /" | sudo tee /etc/apt/sources.list.d/cirruslabs.list
```

Update the package index files and install the Orchard Controller:

```shell
sudo apt-get update && sudo apt-get -y install orchard-controller
```

Finally, enable and start the Orchard Controller systemd service:

```shell
sudo systemctl enable orchard-controller
sudo systemctl start orchard-controller
```

The bootstrap credentials will be printed to the standard output. You can inspect them by running `sudo systemctl status orhcard-controller` or `journalctl -u orchard-controller`.

### systemd service on RPM-based distributions

This should work for most RPM-based distributions like Fedora, CentOS, etc.

First, create a `/etc/yum.repos.d/cirruslabs.repo` file with the following contents:

```ini
[cirruslabs]
name=Cirrus Labs Repo
baseurl=https://yum.fury.io/cirruslabs/
enabled=1
gpgcheck=0
```

Then, install the Orchard Controller:

```shell
sudo yum -y install orchard-controller
```

Finally, enable and start the Orchard Controller systemd service:

```shell
systemctl enable orchard-controller
systemctl start orchard-controller
```

The bootstrap credentials will be printed to the standard output. You can inspect them by running `sudo systemctl status orhcard-controller` or `journalctl -u orchard-controller`.
