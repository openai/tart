---
draft: false
date: 2023-02-11
search:
  exclude: true
authors:
  - fkorotkov
categories:
  - announcement
---

# Changing Tart License

!!! note "Current license"
    This post describes a historical license change announced on February 11, 2023.
    As of June 5, 2026, Tart is maintained by OpenAI and licensed under
    [FSL-1.1-ALv2](https://github.com/openai/tart/blob/main/LICENSE).
    The usage limits, paid tiers, pricing, support commitments, and contact details described below no longer apply.

**TLDR:** We are transitioning Tart's licensing from AGPL-3.0 to [Fair Source 100](https://fair.io/). This change will
permit unlimited installations on personal computers, but organizations that exceed a certain number of server
installations utilizing 100 CPU cores will be required to obtain a paid license.

## Background

Exactly a year ago on February 11th 2022 we started working on Tart – a tiny CLI to run macOS virtual machines on Apple Silicon.
Three months later we successfully started using Tart in our own production system and decided to share Tart with everyone.

<img src="https://github.com/openai/tart/raw/main/Resources/TartSocial.png"/>

The goal was to establish a community of users and contributors to transform Tart from a small CLI to a robust tool
for various scenarios. **Unfortunately, we were not successful in attracting a significant number of contributors.**
It's important to note that we did have seven individuals who contributed to the development of Tart to the best of
their abilities. However, one of the challenges of contributing to Tart is that the skill set required for a contribution
is vastly different from the skill set typically possessed by regular Tart users in their daily work. Specifically,
a contributor needs to have knowledge of the Swift programming language, as well as a background in operating systems
and network stack. This is the reason why **98.8% of the code and all the major features were contributed by Cirrus Labs engineers.**

<!-- more -->

Tart is experiencing significant success among users and has seen widespread adoption for various applications.
The latest macOS Ventura virtual machine image has been downloaded over 27,000 times! We are continually receiving
feedback from an increasing number of users who are utilizing Tart in ways we had not initially anticipated. However,
with a growing user base comes a rise in requests for new features and enhancements. It can be challenging to justify
dedicating our engineering resources to meeting these demands when they do not align with the needs of our company, Cirrus Labs.
As a small, self-funded organization, our priority is to provide for our employees and their families along with developing great products.

In addition, the **decision to use AGPL-3.0 as the license for Tart was not thoroughly considered at the time of its release.**
The choice was made because many companies that were commercializing their products had recently switched to the AGPL license.
However, AGPL has a reputation for being viral, open to interpretation, and not in line with current standards. Additionally,
many organizations have policies against using any AGPL-licensed software in their stacks, which has limited Tart's potential
for wider adoption. See [Google's AGPL policy](https://opensource.google/documentation/reference/using/agpl-policy), for example.

In order to ensure Tart's long-term viability and to allow us to allocate engineering resources towards further improving Tart,
we plan to transition to a licensing model that includes a nominal fee for companies that reach a substantial level of usage.

## What is changing

In the near future, we are set to launch the first version of Orchard for Tart, a tool that facilitates the coordination
of Tart virtual machines on a cluster of Apple Silicon servers. Concurrently, we will also release version 1.0.0 of Tart,
which will establish a stable API and offer long-term support under a new Fair Source 100 license.

The Fair Source 100 license for Tart means that once a certain threshold of server installations utilizing 100 CPU cores
is exceeded, a paid license will be required. A "server installation" refers to the installation of Tart on a physical
device without a physical display connected. For example, a Mac Mini with a HDMI Dummy Plug is considered a server,
but a Mac Mini on a desk with a connected physical display is considered a personal computer. **Usage on personal computers
and before reaching the 100 CPU cores limit is royalty-free and does not have the viral properties of AGPL.**

When an organization surpasses the 100 CPU cores limit, they will be required to obtain a Gold Tier License,
which costs \$12,000 per year. Upon reaching a limit of 500 CPU cores, a Platinum Tier License
(\$36,000 per year) will be required, and for organizations that exceed 3000 CPU cores, a custom Diamond Tier License
(\$12 per core per year) will be necessary. **All paid license tiers will include priority feature development and SLAs on support with urgent issues.**

## Have we considered alternatives?

We have evaluated other options. Initially, we reached out to some of our largest users and asked them to consider
sponsoring the development of features that they were interested in. However, we received no response or were eventually
ignored. Another option we considered was using the open core model and developing enterprise-specific features. However,
this approach is not addressing concerns related to the viral nature of AGPL for non-enterprise users. Ultimately,
we concluded that transitioning to a source-available model with a mandatory paid licensing is fair, as the licensing fees
are relatively insignificant for companies that reach a significant level of usage.

If the new licensing model is not suitable for your organization, you are welcome to continue using the AGPL version of Tart,
but please ensure it is not used in a non-AGPL environment.
