---
title: Automating VM image building with Packer
description: Use Packer to build custom VM images, configure VMs and work with remote OCI registries.
---

Please refer to [Tart Packer Plugin repository](https://github.com/cirruslabs/packer-plugin-tart) for setup instructions.
Here is an example of a template to build a local image based of a remote image:

```hcl
packer {
  required_plugins {
    tart = {
      version = ">= 0.5.3"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

source "tart-cli" "tart" {
  vm_base_name = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
  vm_name      = "my-custom-tahoe"
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 70
  ssh_password = "admin"
  ssh_timeout  = "120s"
  ssh_username = "admin"
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "shell" {
    inline = ["echo 'Disabling spotlight indexing...'", "sudo mdutil -a -i off"]
  }

  # more provisioners
}
```

Here is a [repository with Packer templates](https://github.com/cirruslabs/macos-image-templates) used to build [all the images managed by Cirrus Labs](https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos).
