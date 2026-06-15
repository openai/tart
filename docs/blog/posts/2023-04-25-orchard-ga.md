---
draft: false
date: 2023-04-25
search:
  exclude: true
authors:
  - fkorotkov
categories:
  - announcement
  - orchard
---

# Announcing Orchard orchestration for managing macOS virtual machines at scale

Today we are happy to announce general availability of Orchard – our new orchestrator to manage Tart virtual machines at scale.
In this post we’ll cover the motivation behind creating yet another orchestrator and why we didn’t go with Kubernetes or Nomad integration.

## What problem are we trying to solve?

After releasing Tart we pretty quickly started getting requests about managing macOS virtual machines on a cluster of
Apple Silicon machines rather than just a single host which only allows a maximum of two virtual machines at a time.
By the end of 2022 the requests reached a tipping point, and we started planning.

<!-- more -->

First, we established some constraints about the end users and potential workload our solution should handle.
Running macOS or Linux virtual machines on Apple Silicon is a very niche use case. These VMs are either used in
automation solutions like CI/CD or for managing remote desktop environments. In this case **we are aiming to manage
only thousands of virtual machines and not millions**.

Second, **operators of such solutions won’t have experience of operating Kubernetes or Nomad**. Operators will most likely
come with experience of using such systems but not managing them. And again, having built-in things like RBAC and
ability to scale to millions were appealing but it seemed like it would be a solution for a few rather than a solution
for everybody to use. Additionally Orchard should provide **first class support for accessing virtual machines over SSH/VNC**
and support script execution.

By that time, the idea of building a simple opinionated orchestrator got more and more appealing. Plus we kind of already did it
for [Cirrus CI’s persistent workers](https://cirrus-ci.org/guide/persistent-workers/) feature.

## Technical constraints

With the UX constraints and expectations in place we started thinking about architecture for the orchestrator that we
started calling **Orchard**.

<script src="https://unpkg.com/@dotlottie/player-component@latest/dist/dotlottie-player.js"></script>
<dotlottie-player
src="/assets/animations/Orchard.lottie"
mode="normal"
style="width: 100%; height: 360px; margin: auto; background-color: rgb(5 62 94)"
autoplay
loop
/>

Since Orchard will manage a maximum of a couple thousands virtual machines and not millions we **decided to not think much
about horizontal scalability.** Just a single instance of Orchard controller should be enough if it can restart quickly and
persist state between restarts.

**Orchard should be secure by default**. All the communication between a controller and workers should be secure.
All external API requests to Orchard controller should be authorized.

During development it’s crucial to have a quick feedback cycle. **It should be extremely easy to run Orchard in development**.
Configuring a production cluster should be also easy for novice operators.

## High-level implementation details

Cirrus Labs started as a predominantly Kotlin shop with a little Go. But over the years we gradually moved a lot of things to Go.
We love the expressibility of Kotlin as a language but the ecosystem for writing system utilities and services is superb in Go.

Orchard is a single Go project that implements both controller server interface and worker client logic in a single repository.
This simplifies code sharing and testability of the both components and allows to change them in a single pull request.

Another benefit is that Orchard can be distributed as a single binary. We intend to run Orchard controller on a single host.
Data model for the orchestration didn’t look complex as well. These observations lead us to exploring the use of an embedded database.
Just imagine! **Orchard can be distributed as a single binary with no external dependencies on any database or runtime!**

And we did exactly that! Orchard is distributed as a single binary that can be run in “controller” mode on a Linux/macOS host and
in “worker” mode on macOS hosts. Orchard controller is using extremely fast [BadgerDB](https://dgraph.io/docs/badger/) key-value storage to persist data.

## Conclusion

Please give [Orchard](https://github.com/openai/orchard) a try! To run it locally in development mode on any Apple Silicon device
please run the following command:

```bash
brew install cirruslabs/cli/orchard
orchard dev
```

This will launch a development cluster with a single worker on your machine. Refer to [Orchard documentation](https://github.com/openai/orchard#creating-virtual-machines)
on how to create your first virtual machine and access it.

In a [separate blog post](2023-04-28-orchard-ssh-over-grpc.md)
we’ll cover how Orchard implements seamless SSH access over a gRPC connection. Stay tuned and please don’t hesitate to
[open an issue](https://github.com/openai/orchard/issues)!
