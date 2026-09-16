package integration_test

import (
    "compress/gzip"
    "encoding/hex"
    "integration/tart"
    "io"
    "net/http"
    "net/http/httptest"
    "net/url"
    "testing"
    "time"

    "github.com/stretchr/testify/require"
    semconv "go.opentelemetry.io/otel/semconv/v1.37.0"
    tracepkg "go.opentelemetry.io/proto/otlp/collector/trace/v1"
    v1 "go.opentelemetry.io/proto/otlp/common/v1"
    "google.golang.org/protobuf/proto"
)

func TestOpenTelemetry(t *testing.T) {
    // Start a mock OpenTelemetry collector server
    traces := make(chan *tracepkg.ExportTraceServiceRequest, 1)

    server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
        var trace tracepkg.ExportTraceServiceRequest

        reader := request.Body
        var err error

        if request.Header.Get("Content-Encoding") == "gzip" {
            reader, err = gzip.NewReader(reader)
            require.NoError(t, err)
        }

        requestBytes, err := io.ReadAll(reader)
        require.NoError(t, err)

        switch request.Header.Get("Content-Type") {
        case "application/x-protobuf":
            require.NoError(t, proto.Unmarshal(requestBytes, &trace))
        default:
            require.FailNowf(t, "unsupported content type",
                "we do not support %q yet", request.Header.Get("Content-Type"))
        }

        select {
        case traces <- &trace:
        default:
            t.Error("received an unexpected additional trace")
        }

        var response tracepkg.ExportTraceServiceResponse

        responseBytes, err := proto.Marshal(&response)
        require.NoError(t, err)

        writer.Header().Set("Content-Type", "application/x-protobuf")
        _, err = writer.Write(responseBytes)
        require.NoError(t, err)
    }))
    t.Cleanup(server.Close)

    // Start a "tart list" command
    serverURL, err := url.Parse(server.URL)
    require.NoError(t, err)

    t.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", serverURL.JoinPath("v1/traces").String())
    t.Setenv("CIRRUS_SENTRY_TAGS", "A=B,C=D")
    t.Setenv("TRACEPARENT", "00-00000000000000000000000000000001-0000000000000001-01")

    _, _, err = tart.Tart(t, "list")
    require.NoError(t, err)

    // Ensure that the mock OpenTelemetry collector received a trace from "tart list"
    var trace *tracepkg.ExportTraceServiceRequest
    select {
    case trace = <-traces:
    case <-time.After(5 * time.Second):
        t.Fatal("timed out waiting for OpenTelemetry trace")
    }
    server.Close()
    require.Empty(t, traces, "received an unexpected additional trace")

    resourceSpans := trace.GetResourceSpans()
    require.Len(t, resourceSpans, 1)

    // Ensure that service name and version resources are set
    resourceSpan := resourceSpans[0]
    stringAttributes := stringAttributesToMap(resourceSpan.GetResource().GetAttributes())
    require.Equal(t, "tart", stringAttributes[string(semconv.ServiceNameKey)])
    require.Equal(t, "SNAPSHOT", stringAttributes[string(semconv.ServiceVersionKey)])

    scopeSpans := resourceSpan.GetScopeSpans()
    require.Len(t, scopeSpans, 1)

    spans := scopeSpans[0].GetSpans()
    require.Len(t, spans, 1)

    // Ensure that the root span is correctly named
    span := spans[0]
    require.Equal(t, "list", span.Name)

    // Ensure that CIRRUS_SENTRY_TAGS are propagated
    stringAttributes = stringAttributesToMap(span.GetAttributes())
    require.Equal(t, stringAttributes["A"], "B")
    require.Equal(t, stringAttributes["C"], "D")

    // Ensure that W3C Trace Context is propagated
    require.Equal(t, "00000000000000000000000000000001", hex.EncodeToString(span.GetTraceId()))
    require.Equal(t, "0000000000000001", hex.EncodeToString(span.GetParentSpanId()))
}

func stringAttributesToMap(attributes []*v1.KeyValue) map[string]string {
    result := map[string]string{}

    for _, attribute := range attributes {
        result[attribute.GetKey()] = attribute.GetValue().GetStringValue()
    }

    return result
}
