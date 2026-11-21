package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHarnessAggregationAndSanitization(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-only" {
			t.Error("missing auth")
		}
		w.Write([]byte(`{"node":"private-node-name","sku":"test-sku","nodeCpuUtilization":0.25,"metricTimestamp":"2026-01-01T00:00:00Z","orcaEmitted":true}`))
	}))
	defer server.Close()
	output := run(server.URL, "test-only", "synthetic-test", 100*time.Millisecond, 2)
	if output.Success == 0 || output.Errors != 0 || len(output.Nodes) != 1 {
		t.Fatal("benchmark did not collect responses")
	}
	a := output.Nodes["node-1"]
	if a == nil || a.Share != 100 || a.CPU != 25 || a.CPUSamples != 1 {
		t.Fatal("CPU samples must be deduplicated by timestamp, names anonymized")
	}
	for name := range output.Nodes {
		if strings.Contains(name, "private") {
			t.Fatal("raw node name escaped")
		}
	}
}

func TestHarnessCountsHTTPFailures(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) }))
	defer server.Close()
	output := run(server.URL, "test-only", "synthetic-test", 50*time.Millisecond, 1)
	if output.Errors == 0 || output.Success != 0 || output.ErrorKinds["http-503"] != output.Errors {
		t.Fatal("HTTP errors must not become successes")
	}
}

func TestPhaseBoundaryBodyCancellationIsExcluded(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"node":`))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	output := run(server.URL, "test-only", "synthetic-test", 50*time.Millisecond, 1)
	if output.Errors != 0 || output.Success != 0 {
		t.Fatal("planned deadline cancellation must not become a benchmark error")
	}
}
