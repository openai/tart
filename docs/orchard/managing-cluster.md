## Backups

In order to backup the Orchard Controller, simply copy its `ORCHARD_HOME` (which defaults to `~/.orchard/`) directory somewhere safe and restore it when needed.

This directory contains a BadgerDB database that Controller uses to store state and an X.509 certificate with key.

## Upgrades

Since the Orchard's initial release, we've managed to maintain the backwards compatibility between versions up to this day, so generally, it doesn't matter whether you upgrade the Controller or Worker(s) first.

In case a new functionality is introduced, you might be required to finish the upgrade of both the Controller and the Worker(s) to be able to use it fully.

In case there will be backwards-incompatible changes introduced in the future, we will try to do our best and highlight this in the [release notes](https://github.com/openai/orchard/releases) accordingly.

## Observability

Both the Controller and Worker produce some useful OpenTelemetry metrics. Metrics are scoped with `org.cirruslabs.orchard` prefix and include information about resource utilization, statuses or Workers, scheduling/pull time and many more.

By default, the telemetry is sent to `https://localhost:4317` using the gRPC protocol and to `http://localhost:4318` using the HTTP protocol.

You can override this by setting the [standard OpenTelemetry environment variable](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/) `OTEL_EXPORTER_OTLP_ENDPOINT`.

Please refer to [OTEL Collector documentation](https://opentelemetry.io/docs/collector/) for instruction on how to setup a sidecar for the metrics collections or find out if your SaaS monitoring has an available OTEL endpoint (see [Honeycomb](https://docs.honeycomb.io/send-data/opentelemetry/) as an example).

### Sending metrics to Google Cloud Platform

There are two standard options of ingesting metrics procuded by Orchard Controller and Workers into the GCP:

* [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) + [Google Cloud Exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/googlecloudexporter/README.md) — open-source solution that can be later re-purposed to send metrics to any OTLP-compatible endpoint by swapping a single [exporter](https://opentelemetry.io/docs/collector/configuration/#exporters)
* [Ops Agent](https://cloud.google.com/monitoring/agent/ops-agent/otlp) — Google-backed solution with a syntax similar to OpenTelemetry Collector, but tied to GCP-only
